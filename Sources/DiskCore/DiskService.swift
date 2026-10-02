import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let output: Data
    public let error: Data
    public let exitCode: Int32
    public init(output: Data, error: Data = Data(), exitCode: Int32 = 0) {
        self.output = output; self.error = error; self.exitCode = exitCode
    }
    public var errorText: String { String(data: error, encoding: .utf8) ?? "" }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
    public init() {}
    public func run(_ executable: String, arguments: [String], timeout: TimeInterval = 20) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            // Foundation Process lifecycle stays on one worker thread. Suspending an
            // async task between run() and completion can move it to another thread.
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try Self.runBlocking(executable, arguments: arguments, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func runBlocking(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("MacDiskTemp-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        for url in [stdoutURL, stderrURL] {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DiskError("조회 준비 실패", "임시 출력 파일을 만들 수 없습니다.")
            }
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timedOut = false
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 0.15)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Completion has already been observed. No second run-loop-based wait is needed.
        if timedOut { throw DiskError("디스크 응답 시간 초과", "장치가 \(Int(timeout))초 안에 응답하지 않았습니다. 연결 상태를 확인한 후 다시 시도하세요.") }
        // File output avoids a full stdout/stderr pipe blocking the child process.
        for url in [stdoutURL, stderrURL] {
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 8_000_000 { throw DiskError("응답 크기 초과", "장치 응답이 예상 크기를 초과했습니다.") }
        }
        return CommandResult(output: try Data(contentsOf: stdoutURL), error: try Data(contentsOf: stderrURL), exitCode: process.terminationStatus)
    }
}

public struct DiskService: Sendable {
    let runner: any CommandRunning
    public init(runner: any CommandRunning = ProcessRunner()) { self.runner = runner }

    public static func smartctlPath(customPath: String = "") -> String? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = trimmed.isEmpty
            ? ["/opt/homebrew/bin/smartctl", "/opt/homebrew/sbin/smartctl", "/usr/local/bin/smartctl", "/usr/local/sbin/smartctl", "/opt/local/sbin/smartctl"]
            : [trimmed]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func disks() async throws -> [PhysicalDisk] {
        let result = try await runner.run("/usr/sbin/diskutil", arguments: ["list", "-plist", "physical"], timeout: 15)
        guard result.exitCode == 0 else {
            throw DiskError("디스크 목록을 읽을 수 없습니다", "macOS에서 디스크 목록을 가져오지 못했습니다. 잠시 후 새로고침하세요.", details: result.errorText)
        }
        let disks = try DiskParser.physicalDisks(from: result.output)
        return await withTaskGroup(of: PhysicalDisk.self) { group in
            for disk in disks {
                group.addTask {
                    guard let info = try? await runner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", disk.path], timeout: 10),
                          info.exitCode == 0, let enriched = try? DiskParser.enrich(disk, from: info.output) else { return disk }
                    return enriched
                }
            }
            var enriched: [PhysicalDisk] = []
            for await disk in group { enriched.append(disk) }
            return enriched.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
    }

    public func snapshot(for disk: PhysicalDisk, smartctlPath: String) async throws -> SMARTSnapshot {
        guard DiskParser.isWholeDiskID(disk.id) else { throw DiskError("잘못된 디스크", "물리 디스크를 다시 선택하세요.") }
        let result = try await runner.run(smartctlPath, arguments: ["-a", "--json=ov", disk.path], timeout: 20)
        if result.output.isEmpty { throw DiskError.smartFailure(result.errorText) }
        return try SMARTParser.parse(result.output, exitCode: result.exitCode)
    }
}
