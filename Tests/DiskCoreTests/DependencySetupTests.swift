import XCTest
@testable import DiskCore

final class DependencySetupTests: XCTestCase {
    private var folder: URL!
    private var session: URL { folder.appendingPathComponent("session") }
    private var brew: URL { folder.appendingPathComponent("brew") }
    private var smartctl: URL { folder.appendingPathComponent("smartctl") }
    private var downloader: URL { folder.appendingPathComponent("curl") }
    private var events: URL { folder.appendingPathComponent("events") }
    private func quote(_ url: URL) -> String { DependencySetup.shellQuote(url.path) }
    private var status: String { (try? String(contentsOf: session.appendingPathComponent("status"), encoding: .utf8)) ?? "" }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Setup test ' $(unwanted)-\(UUID())")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func executable(_ url: URL, _ body: String) throws {
        try ("#!/bin/bash\nset -eu\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func run() async throws -> CommandResult {
        let script = session.appendingPathComponent("install.command")
        try DependencySetup.script(directory: session, brewPaths: [brew.path], smartctlPaths: [smartctl.path],
                                   downloader: downloader.path).write(to: script, atomically: true, encoding: .utf8)
        return try await ProcessRunner().run("/bin/bash", arguments: [script.path], timeout: 10)
    }
    private func makeBrew(fails: Bool = false) throws {
        try executable(brew, """
        [[ "$#" == 2 && "$1" == install && "$2" == smartmontools ]]
        [[ "$HOMEBREW_NO_ANALYTICS" == 1 ]]
        printf 'brew\\n' >> \(quote(events))
        \(fails ? "exit 42" : "")
        printf '#!/bin/bash\\n[[ \"$1\" == --version ]]\\n' > \(quote(smartctl))
        /bin/chmod 700 \(quote(smartctl))
        """)
    }

    func testExistingSmartctlSkipsBothInstallers() async throws {
        try executable(smartctl, "[[ \"$1\" == --version ]]\nprintf 'smartctl 7.5\\n'")
        let result = try await run()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(status, "complete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.path))
    }

    func testExistingBrewInstallsOnlySmartmontoolsWithQuotedPaths() async throws {
        try makeBrew()
        let result = try await run()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(status, "complete")
        XCTAssertEqual(try String(contentsOf: events, encoding: .utf8), "brew\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("unwanted").path))
    }

    func testMissingBrewDownloadsOfficialInstallerThenInstallsTool() async throws {
        try makeBrew()
        let template = folder.appendingPathComponent("brew-template")
        try FileManager.default.moveItem(at: brew, to: template)
        let installer = folder.appendingPathComponent("installer-template")
        try executable(installer, "/bin/cp \(quote(template)) \(quote(brew))\nprintf 'homebrew\\n' >> \(quote(events))")
        try executable(downloader, """
        output=''
        for ((i=1; i<=$#; i++)); do
            if [[ "${!i}" == --output ]]; then j=$((i+1)); output="${!j}"; fi
        done
        [[ "${!#}" == https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh ]]
        /bin/cp \(quote(installer)) "$output"
        """)
        let result = try await run()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(status, "complete")
        XCTAssertEqual(try String(contentsOf: events, encoding: .utf8), "homebrew\nbrew\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("homebrew-install.sh").path))
    }

    func testDownloadFailureDoesNotContinueInstallation() async throws {
        try executable(downloader, "exit 22")
        let result = try await run()
        XCTAssertEqual(result.exitCode, 22)
        XCTAssertEqual(status, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: smartctl.path))
    }

    func testBrewFailureRemainsFailure() async throws {
        try makeBrew(fails: true)
        let result = try await run()
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertEqual(status, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: smartctl.path))
    }

    func testBrokenInstalledExecutableIsNotReportedAsSuccess() async throws {
        try executable(smartctl, "exit 9")
        let result = try await run()
        XCTAssertEqual(result.exitCode, 9)
        XCTAssertEqual(status, "failed")
    }

    func testDuplicateLaunchDoesNotRunAnotherInstaller() async throws {
        try FileManager.default.createDirectory(at: session.appendingPathComponent("running"), withIntermediateDirectories: false)
        try "homebrew".write(to: session.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        try makeBrew()
        let result = try await run()
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(status, "homebrew")
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.path))
    }
}
