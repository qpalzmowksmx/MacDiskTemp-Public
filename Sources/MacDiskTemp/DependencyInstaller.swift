import AppKit
import Darwin
import DiskCore

@MainActor
final class DependencyInstaller: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var completed = false
    @Published private(set) var message = ""
    @Published private(set) var failure: String?
    private var task: Task<Void, Never>?
    private var directory: URL?
    private let defaultsKey = "dependencyInstallationSession"

    init() {
        // Reattach if the app was quit while Terminal continued installing.
        if let path = UserDefaults.standard.string(forKey: defaultsKey) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let parent = FileManager.default.temporaryDirectory.standardizedFileURL
            let name = url.lastPathComponent
            if url.deletingLastPathComponent().path == parent.path,
               name.hasPrefix("MacDiskTemp-Setup-"),
               UUID(uuidString: String(name.dropFirst("MacDiskTemp-Setup-".count))) != nil,
               FileManager.default.fileExists(atPath: url.path) {
                directory = url
                isRunning = true
                message = "진행 중이던 설치를 확인하는 중…"
                task = Task { await observe(url) }
            } else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }
    }

    func start() {
        guard !isRunning else { return }
        completed = false
        failure = nil
        do {
            let fm = FileManager.default
            let url = fm.temporaryDirectory.appendingPathComponent("MacDiskTemp-Setup-\(UUID().uuidString)")
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let script = url.appendingPathComponent("MacDiskTemp 설치.command")
            try DependencySetup.script(directory: url).write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            try "starting".write(to: url.appendingPathComponent("status"), atomically: true, encoding: .utf8)
            directory = url
            UserDefaults.standard.set(url.path, forKey: defaultsKey)
            isRunning = true
            message = "설치 창을 여는 중…"
            task = Task {
                do {
                    guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                        throw DiskError("설치 창을 열 수 없습니다", "macOS 터미널 앱을 찾을 수 없습니다.")
                    }
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        NSWorkspace.shared.open([script], withApplicationAt: terminal,
                                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                    await observe(url)
                } catch { finish(error.localizedDescription) }
            }
        } catch { finish(error.localizedDescription) }
    }

    func showTerminal() {
        // Activate the existing window; reopening the script could start another run.
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal")
            .first?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func observe(_ url: URL) async {
        let fm = FileManager.default
        let created = (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
        while !Task.isCancelled {
            let status = (try? String(contentsOf: url.appendingPathComponent("status"), encoding: .utf8)) ?? "starting"
            switch status {
            case "complete":
                guard let path = DiskService.smartctlPath() else {
                    finish("설치가 끝났지만 smartctl을 찾지 못했습니다. 경로 설정을 확인하세요.")
                    return
                }
                do {
                    let result = try await ProcessRunner().run(path, arguments: ["--version"], timeout: 10)
                    guard result.exitCode == 0 else { throw DiskError("설치 확인 실패", "smartctl을 실행할 수 없습니다.") }
                    completed = true
                    message = "설치가 완료되었습니다."
                    isRunning = false
                    clearSession()
                } catch { finish(error.localizedDescription) }
                return
            case "failed": finish("설치가 완료되지 않았습니다. 터미널의 오류 메시지를 확인하고 다시 시도하세요."); return
            case "cancelled": finish("설치가 중단되었습니다. 준비되면 다시 시도하세요."); return
            case "homebrew": message = "Homebrew 설치 중 · 터미널에서 비밀번호와 설치 확인에 응답하세요."
            case "smartmontools": message = "디스크 정보를 읽는 smartmontools를 설치하는 중…"
            case "verifying": message = "설치한 도구가 실행되는지 확인하는 중…"
            default: message = "터미널에서 설치를 시작하는 중…"
            }
            if let pidText = try? String(contentsOf: url.appendingPathComponent("pid"), encoding: .utf8),
               let pid = Int32(pidText), pid > 0 {
                if kill(pid, 0) != 0 && errno == ESRCH {
                    // Re-read on the next pass if the process just wrote its final state.
                    let latest = try? String(contentsOf: url.appendingPathComponent("status"), encoding: .utf8)
                    if latest == status { finish("설치 창이 종료되었습니다. 다시 시도하세요."); return }
                }
            } else if Date().timeIntervalSince(created) > 120 {
                finish("설치가 시작되지 않았습니다. 터미널 창을 확인한 뒤 다시 시도하세요.")
                return
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }

    private func finish(_ error: String) {
        isRunning = false
        failure = error
        clearSession()
    }

    private func clearSession() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
