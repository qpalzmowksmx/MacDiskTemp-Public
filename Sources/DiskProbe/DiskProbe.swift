import Foundation
import DiskCore

/// Developer smoke check: exercises the same discovery and parser as the app, without a UI.
@main
struct DiskProbe {
    static func main() async {
        do {
            let service = DiskService()
            let disks = try await service.disks()
            guard let path = DiskService.smartctlPath() else { throw DiskError.missingTool }
            print("물리 디스크 \(disks.count)개 · smartctl \(path)")
            var failure = false
            for disk in disks {
                do {
                    let report = try await service.snapshot(for: disk, smartctlPath: path)
                    print("\(disk.path) | \(disk.location) | \(disk.name) | \(disk.capacity) | \(report.temperatureText) | \(report.health.title)")
                    print("  누적 읽기 \(report.bytesRead.map(DisplayFormat.bytes) ?? "—") · 쓰기 \(report.bytesWritten.map(DisplayFormat.bytes) ?? "—") · 원문 \(report.rawText.count)자")
                    if let usage = try await service.storageUsage(for: disk) {
                        print("  저장 공간 \(usage.usedPercentage.formatted(.number.precision(.fractionLength(1))))% · \(DisplayFormat.bytes(usage.usedBytes)) / \(DisplayFormat.bytes(usage.totalBytes)) · \(usage.scope)")
                    }
                } catch {
                    failure = true
                    print("\(disk.path) | \(error.localizedDescription)")
                    if let error = error as? DiskError, !error.details.isEmpty { print(error.details) }
                }
            }
            if failure { exit(1) }
        } catch {
            print(error.localizedDescription)
            exit(1)
        }
    }
}
