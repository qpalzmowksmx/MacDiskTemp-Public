import XCTest
@testable import DiskCore

final class DiskCoreTests: XCTestCase {
    private func json(_ source: String) -> Data { Data(source.utf8) }
    private func plist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    func testNVMeValuesAndOriginalOutput() throws {
        let report = try SMARTParser.parse(json("""
        {"smartctl":{"exit_status":0,"output":["SMART report","Temperature: 47 Celsius"]},
         "device":{"protocol":"NVMe"},"model_name":"SOLIDIGM SSDPFKKW020X7",
         "smart_status":{"passed":true},"temperature":{"current":47,"op_limit_max":86,"critical_limit_max":87},
         "nvme_smart_health_information_log":{"critical_warning":0,"temperature":47,"percentage_used":0,
         "available_spare":100,"available_spare_threshold":10,"data_units_read":19385480,
         "data_units_written":10733697,"power_on_hours":370,"media_errors":0,"temperature_sensors":[41,44]}}
        """))
        XCTAssertEqual(report.temperature, 47)
        XCTAssertEqual(report.health, .healthy)
        XCTAssertEqual(report.percentageUsed, 0)
        XCTAssertEqual(report.availableSpare, 100)
        XCTAssertEqual(report.bytesRead, 9_925_365_760_000)
        XCTAssertEqual(report.bytesWritten, 5_495_652_864_000)
        XCTAssertEqual(report.sensors, [41, 44])
        XCTAssertEqual(report.rawText, "SMART report\nTemperature: 47 Celsius")
    }

    func testFailingExitStatusStillDisplaysTelemetry() throws {
        let report = try SMARTParser.parse(json("""
        {"smartctl":{"exit_status":8},"smart_status":{"passed":false},"temperature":{"current":47}}
        """), exitCode: 8)
        XCTAssertEqual(report.temperature, 47)
        XCTAssertEqual(report.health, .failing)
        XCTAssertFalse(report.warnings.isEmpty)
    }

    func testPartialFailurePreservesUsableReadings() throws {
        let report = try SMARTParser.parse(json("""
        {"smart_status":{"passed":true},"temperature":{"current":36}}
        """), exitCode: 4)
        XCTAssertEqual(report.health, .warning)
        XCTAssertEqual(report.temperature, 36)
        XCTAssertTrue(report.warnings.first!.contains("부분 응답"))
    }

    func testHistoricalErrorFlagsDoNotAppearHealthy() throws {
        for code: Int32 in [32, 64, 128] {
            let report = try SMARTParser.parse(json(#"{"smart_status":{"passed":true}}"#), exitCode: code)
            XCTAssertEqual(report.health, .warning)
        }
    }

    func testCurrentPrefailureAttributeIsFailing() throws {
        let report = try SMARTParser.parse(json(#"{"smart_status":{"passed":true}}"#), exitCode: 16)
        XCTAssertEqual(report.health, .failing)
    }

    func testNVMeCriticalWarningCannotBeGreen() throws {
        let report = try SMARTParser.parse(json("""
        {"smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":4}}
        """))
        XCTAssertEqual(report.health, .failing)
    }

    func testNoHealthVerdictIsUnknown() throws {
        let report = try SMARTParser.parse(json(#"{"temperature":{"current":40}}"#))
        XCTAssertNil(report.passed)
        XCTAssertEqual(report.health, .unknown)
    }

    func testMissingValuesRemainMissingInsteadOfZero() throws {
        let report = try SMARTParser.parse(json(#"{"smart_status":{"passed":true}}"#))
        XCTAssertNil(report.temperature)
        XCTAssertNil(report.percentageUsed)
        XCTAssertNil(report.bytesWritten)
        XCTAssertEqual(report.metrics.first(where: { $0.id == "errors" })?.value, "—")
    }

    func testThresholdsComeFromDevice() throws {
        let warning = try SMARTParser.parse(json("""
        {"smart_status":{"passed":true},"temperature":{"current":86,"op_limit_max":86,"critical_limit_max":87}}
        """))
        let critical = try SMARTParser.parse(json("""
        {"smart_status":{"passed":true},"temperature":{"current":87,"op_limit_max":86,"critical_limit_max":87}}
        """))
        XCTAssertEqual(warning.health, .warning)
        XCTAssertEqual(critical.health, .failing)
    }

    func testWornOutAndLowSpareAreWarnings() throws {
        let report = try SMARTParser.parse(json("""
        {"smart_status":{"passed":true},"nvme_smart_health_information_log":
        {"percentage_used":103,"available_spare":5,"available_spare_threshold":10}}
        """))
        XCTAssertEqual(report.health, .warning)
        XCTAssertEqual(report.percentageUsed, 103)
        XCTAssertEqual(report.warnings.count, 2)
    }

    func testATAReadingsAndVendorSpecificRawValues() throws {
        let report = try SMARTParser.parse(json("""
        {"device":{"protocol":"ATA"},"smart_status":{"passed":true},"temperature":{"current":35},
        "power_on_time":{"hours":9123},"power_cycle_count":87,
        "ata_smart_attributes":{"table":[{"id":241,"name":"Total_LBAs_Written","value":100,"thresh":0,
        "raw":{"value":12345,"string":"12345"}}]}}
        """))
        XCTAssertEqual(report.protocolName, "ATA")
        XCTAssertEqual(report.powerOnHours, 9123)
        XCTAssertNil(report.bytesWritten, "Vendor-dependent ATA raw counts must not be assumed to be bytes.")
        XCTAssertEqual(report.metrics.first(where: { $0.id == "ata-241" })?.value, "12345")
    }

    func testWideNVMeCountersUseStringValue() throws {
        let report = try SMARTParser.parse(json("""
        {"smart_status":{"passed":true},"nvme_smart_health_information_log":
        {"data_units_read":0,"data_units_read_s":"9007199254740993"}}
        """))
        XCTAssertEqual(report.bytesRead!, Double("9007199254740993")! * 512_000)
    }

    func testUnsupportedAndInvalidOutputFailClearly() {
        for output in ["not json", "{}", #"{"smart_support":{"available":false}}"#] {
            XCTAssertThrowsError(try SMARTParser.parse(json(output)))
        }
    }

    func testOpenFailureAndPermissionError() {
        XCTAssertThrowsError(try SMARTParser.parse(json("""
        {"smartctl":{"exit_status":2,"messages":[{"string":"Permission denied"}]}}
        """))) { error in
            XCTAssertEqual((error as? DiskError)?.title, "디스크 접근 권한이 필요합니다")
        }
    }

    func testDiskListIncludesOnlyWholeDiskRowsAndDoesNotUseOSInternal() throws {
        let data = try plist(["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk0", "Size": 500_277_792_768, "OSInternal": false],
            ["DeviceIdentifier": "disk6", "Size": 2_048_408_248_320],
            ["DeviceIdentifier": "disk6s2", "Size": 2_048_408_248_320],
            ["DeviceIdentifier": "disk6;echo unsafe"]
        ]])
        let disks = try DiskParser.physicalDisks(from: data)
        XCTAssertEqual(disks.map(\.id), ["disk0", "disk6"])
        XCTAssertNil(disks.first?.isInternal)
        let enriched = try DiskParser.enrich(disks[0], from: plist([
            "DeviceIdentifier": "disk0", "Internal": true, "MediaName": "APPLE SSD",
            "BusProtocol": "Apple Fabric", "SolidState": true, "TotalSize": 500_277_792_768
        ]))
        XCTAssertEqual(enriched.isInternal, true)
        XCTAssertEqual(enriched.name, "APPLE SSD")
    }

    func testDiskPathValidation() {
        XCTAssertTrue(DiskParser.isWholeDiskID("disk12"))
        for value in ["/dev/disk0", "disk0s2", "disk1;id", "disk", "disk-1", "disk0\n"] {
            XCTAssertFalse(DiskParser.isWholeDiskID(value), value)
        }
    }

    func testProcessCapturesNonzeroExitAndBothStreams() async throws {
        let result = try await ProcessRunner().run("/bin/sh", arguments: ["-c", "printf output; printf error >&2; exit 8"], timeout: 2)
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "output")
        XCTAssertEqual(result.errorText, "error")
        XCTAssertEqual(result.exitCode, 8)
    }

    func testProcessTimeout() async {
        do {
            _ = try await ProcessRunner().run("/bin/sleep", arguments: ["5"], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual((error as? DiskError)?.title, "디스크 응답 시간 초과") }
    }

    func testServiceUsesPhysicalFilterAndReadOnlySmartArguments() async throws {
        let runner = RecordingRunner(list: try plist(["AllDisksAndPartitions": [["DeviceIdentifier": "disk6", "Size": 2_000_000_000_000]]]),
                                     info: try plist(["DeviceIdentifier": "disk6", "Internal": false, "MediaName": "External SSD"]),
                                     smart: json(#"{"smart_status":{"passed":true},"temperature":{"current":47}}"#))
        let service = DiskService(runner: runner)
        let disks = try await service.disks()
        let report = try await service.snapshot(for: disks[0], smartctlPath: "/opt/homebrew/bin/smartctl")
        XCTAssertEqual(report.temperature, 47)
        let calls = await runner.calls
        XCTAssertEqual(calls, [["list", "-plist", "physical"], ["info", "-plist", "/dev/disk6"], ["-a", "--json=ov", "/dev/disk6"]])
    }
}

private actor RecordingRunner: CommandRunning {
    var calls: [[String]] = []
    let list: Data, info: Data, smart: Data
    init(list: Data, info: Data, smart: Data) { self.list = list; self.info = info; self.smart = smart }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.append(arguments)
        return CommandResult(output: arguments.first == "list" ? list : arguments.first == "info" ? info : smart)
    }
}
