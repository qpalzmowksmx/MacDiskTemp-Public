import Foundation
import Darwin

/// Synchronous small atomic transactions on the coordinator's actor: no stale async writes.
@MainActor public protocol AlertStateStore: AnyObject {
    func load() throws -> AlertDocument?
    func save(_ document: AlertDocument) throws
}

@MainActor public final class FileAlertStore: AlertStateStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> AlertDocument? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let result = try JSONDecoder().decode(AlertDocument.self, from: data)
        try result.validate()
        return result
    }
    public func save(_ document: AlertDocument) throws {
        try document.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(document)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw AlertFailure("임시 저장 파일을 만들 수 없습니다.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        // All throwing work is before the atomic commit. A reported failure preserves the old file.
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
