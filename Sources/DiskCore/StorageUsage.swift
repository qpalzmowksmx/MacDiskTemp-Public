import Foundation

public struct StorageUsage: Equatable, Sendable {
    public let totalBytes: Double
    public let usedBytes: Double
    public let scope: String
    public var usedPercentage: Double { usedBytes / totalBytes * 100 }
    public var freeBytes: Double { totalBytes - usedBytes }

    public init?(totalBytes: Double, freeBytes: Double, scope: String) {
        guard totalBytes.isFinite, freeBytes.isFinite, totalBytes > 0, freeBytes >= 0, freeBytes <= totalBytes else { return nil }
        self.totalBytes = totalBytes; self.usedBytes = totalBytes - freeBytes; self.scope = scope
    }
}

public enum StorageUsageParser {
    public static func apfsUsage(from data: Data, diskID: String) throws -> StorageUsage? {
        guard DiskParser.isWholeDiskID(diskID),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return nil }
        var total: Double = 0
        var free: Double = 0
        var seen: Set<String> = []
        for container in containers {
            let stores = container["PhysicalStores"] as? [[String: Any]] ?? []
            let identifiers = stores.compactMap { $0["DeviceIdentifier"] as? String }
            guard identifiers.contains(where: { belongs($0, to: diskID) }) else { continue }
            guard !identifiers.isEmpty, identifiers.allSatisfy({ belongs($0, to: diskID) }) else {
                throw DiskError("저장 공간을 구분할 수 없습니다", "여러 물리 디스크가 공유하는 APFS 컨테이너는 디스크별 사용량을 구분할 수 없습니다.")
            }
            guard let id = container["APFSContainerUUID"] as? String ?? container["ContainerReference"] as? String,
                  let capacity = (container["CapacityCeiling"] as? NSNumber)?.doubleValue,
                  let available = (container["CapacityFree"] as? NSNumber)?.doubleValue,
                  StorageUsage(totalBytes: capacity, freeBytes: available, scope: "") != nil else { return nil }
            guard seen.insert(id).inserted else { continue }
            // APFS volumes and snapshots share these blocks; count each container only once.
            total += capacity
            free += available
        }
        return StorageUsage(totalBytes: total, freeBytes: free, scope: "APFS 컨테이너 기준")
    }

    public static func mountedNonAPFSPaths(from data: Data, diskID: String) throws -> [String] {
        guard DiskParser.isWholeDiskID(diskID),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = root["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var paths: Set<String> = []
        for disk in disks where disk["DeviceIdentifier"] as? String == diskID {
            let candidates = [disk] + (disk["Partitions"] as? [[String: Any]] ?? [])
            for item in candidates {
                let content = item["Content"] as? String ?? ""
                guard !content.contains("APFS"), content != "EFI",
                      let id = item["DeviceIdentifier"] as? String, belongs(id, to: diskID),
                      let path = item["MountPoint"] as? String, path.hasPrefix("/") else { continue }
                paths.insert(path)
            }
        }
        return paths.sorted()
    }

    private static func belongs(_ identifier: String, to diskID: String) -> Bool {
        identifier == diskID || identifier.range(of: "\\A\(diskID)s[0-9]+\\z", options: .regularExpression) != nil
    }
}

extension DiskService {
    public func storageUsage(for disk: PhysicalDisk) async throws -> StorageUsage? {
        guard DiskParser.isWholeDiskID(disk.id) else { return nil }
        let apfs = try await runner.run("/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist"], timeout: 15)
        if apfs.exitCode == 0, let usage = try StorageUsageParser.apfsUsage(from: apfs.output, diskID: disk.id) { return usage }

        let list = try await runner.run("/usr/sbin/diskutil", arguments: ["list", "-plist", disk.path], timeout: 15)
        guard list.exitCode == 0 else { return nil }
        let paths = try StorageUsageParser.mountedNonAPFSPaths(from: list.output, diskID: disk.id)
        return try await Task.detached {
            var total: Double = 0
            var free: Double = 0
            for path in paths {
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
                guard let capacity = (attributes[.systemSize] as? NSNumber)?.doubleValue,
                      let available = (attributes[.systemFreeSize] as? NSNumber)?.doubleValue,
                      StorageUsage(totalBytes: capacity, freeBytes: available, scope: "") != nil else { return nil }
                total += capacity
                free += available
            }
            return StorageUsage(totalBytes: total, freeBytes: free, scope: "마운트된 볼륨 기준")
        }.value
    }
}
