import XCTest
@testable import DiskCore

final class DashboardTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    func testMaximumAverageAndMeasuredDuration() throws {
        var history = TemperatureHistory()
        for (offset, temperature) in [(0, 40), (30, 50), (60, 45)] {
            history.record(temperature, for: "ssd", date: start.addingTimeInterval(Double(offset)),
                           uptime: Double(offset), maximumGap: 55)
        }
        let summary = try XCTUnwrap(history.summary(for: "ssd"))
        XCTAssertEqual(summary.maximum, 50)
        XCTAssertEqual(summary.maximumDate, start.addingTimeInterval(30))
        XCTAssertEqual(summary.average, 45)
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.measuredDuration, 60)
    }

    func testMissingReadingsAndPausesDoNotAddFalseSamplesOrDuration() throws {
        var history = TemperatureHistory()
        history.record(30, for: "ssd", date: start, uptime: 0, maximumGap: 55)
        history.record(nil, for: "ssd", date: start.addingTimeInterval(30), uptime: 30, maximumGap: 55)
        history.record(60, for: "ssd", date: start.addingTimeInterval(60), uptime: 60, maximumGap: 55)
        history.pause()
        history.record(45, for: "ssd", date: start.addingTimeInterval(90), uptime: 90, maximumGap: 55)
        let summary = try XCTUnwrap(history.summary(for: "ssd"))
        XCTAssertEqual(summary.average, 45)
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.measuredDuration, 0)
    }

    func testSwitchingDisksPreservesSeparateSessionHistory() throws {
        var history = TemperatureHistory()
        history.record(40, for: "internal", date: start, uptime: 0, maximumGap: 55)
        history.record(80, for: "external", date: start, uptime: 10, maximumGap: 55)
        history.record(50, for: "internal", date: start, uptime: 20, maximumGap: 55)
        XCTAssertEqual(history.summary(for: "internal")?.average, 45)
        XCTAssertEqual(history.summary(for: "external")?.maximum, 80)
        XCTAssertEqual(history.summary(for: "internal")?.measuredDuration, 0)
        XCTAssertNil(TemperatureHistory().summary(for: "internal"), "A fresh app run starts without prior temperature history.")
    }

    func testManualRefreshAndLongSleepDoNotInventMonitoringTime() {
        var history = TemperatureHistory()
        history.record(40, for: "ssd", date: start, uptime: 0, maximumGap: 55)
        history.record(50, for: "ssd", date: start, uptime: 3600, maximumGap: 55)
        history.record(60, for: "ssd", date: start, uptime: 3610, maximumGap: 0)
        XCTAssertEqual(history.summary(for: "ssd")?.measuredDuration, 0)
        XCTAssertEqual(history.summary(for: "ssd")?.sampleCount, 3)
        XCTAssertEqual(history.summary(for: "ssd")?.average, 50)
    }

    func testPhysicalIdentitySurvivesDeviceNumberChange() {
        let first = TemperatureHistory.key(model: "SSD", serial: "SERIAL-A", fallback: "disk6")
        let reconnected = TemperatureHistory.key(model: "SSD", serial: "SERIAL-A", fallback: "disk8")
        let replacement = TemperatureHistory.key(model: "SSD", serial: "SERIAL-B", fallback: "disk6")
        XCTAssertEqual(first, reconnected)
        XCTAssertNotEqual(first, replacement)
    }

    func testFirstReadingAndZeroCelsius() {
        var history = TemperatureHistory()
        XCTAssertNil(history.summary(for: "ssd"))
        history.record(0, for: "ssd", date: start, uptime: 10, maximumGap: 55)
        XCTAssertEqual(history.summary(for: "ssd")?.average, 0)
        XCTAssertEqual(history.summary(for: "ssd")?.maximum, 0)
        XCTAssertEqual(history.summary(for: "ssd")?.sampleCount, 1)
    }

    func testSMARTTemperatureTimesAreIndependentOfSessionStatistics() throws {
        let data = Data("""
        {"smart_status":{"passed":true},"nvme_smart_health_information_log":
        {"temperature":47,"warning_temp_time":125,"critical_comp_time":3}}
        """.utf8)
        let report = try SMARTParser.parse(data)
        XCTAssertEqual(report.warningTemperatureMinutes, 125)
        XCTAssertEqual(report.criticalTemperatureMinutes, 3)
        let missing = try SMARTParser.parse(Data(#"{"temperature":{"current":40}}"#.utf8))
        XCTAssertNil(missing.warningTemperatureMinutes)
        XCTAssertNil(missing.criticalTemperatureMinutes)
    }

    private func container(_ id: String, store: String, total: Int = 1000, free: Int = 250) -> [String: Any] {
        ["APFSContainerUUID": id, "CapacityCeiling": total, "CapacityFree": free,
         "PhysicalStores": [["DeviceIdentifier": store]],
         "Volumes": [["CapacityInUse": 600], ["CapacityInUse": 400]]]
    }

    func testAPFSSharedSpaceIsCountedOncePerContainer() throws {
        let first = container("container-a", store: "disk6s2")
        let second = container("container-b", store: "disk6s3", total: 500, free: 100)
        let data = try plist(["Containers": [first, first, second, container("other", store: "disk0s2")]])
        let usage = try XCTUnwrap(StorageUsageParser.apfsUsage(from: data, diskID: "disk6"))
        XCTAssertEqual(usage.totalBytes, 1500)
        XCTAssertEqual(usage.freeBytes, 350)
        XCTAssertEqual(usage.usedBytes, 1150)
        XCTAssertEqual(usage.usedPercentage, 1150.0 / 1500 * 100, accuracy: 0.001)
    }

    func testDiskOneDoesNotMatchDiskTen() throws {
        let data = try plist(["Containers": [container("other", store: "disk10s2")]])
        XCTAssertNil(try StorageUsageParser.apfsUsage(from: data, diskID: "disk1"))
    }

    func testContainerSpanningPhysicalDisksCannotBeAttributedToOneDisk() throws {
        var shared = container("fusion", store: "disk0s2")
        shared["PhysicalStores"] = [["DeviceIdentifier": "disk0s2"], ["DeviceIdentifier": "disk6s2"]]
        XCTAssertThrowsError(try StorageUsageParser.apfsUsage(from: plist(["Containers": [shared]]), diskID: "disk6"))
    }

    func testInvalidStorageValuesAndMissingCapacityRemainUnknown() throws {
        XCTAssertNil(StorageUsage(totalBytes: 0, freeBytes: 0, scope: ""))
        XCTAssertNil(StorageUsage(totalBytes: 100, freeBytes: 101, scope: ""))
        XCTAssertNil(StorageUsage(totalBytes: 100, freeBytes: -1, scope: ""))
        let full = try XCTUnwrap(StorageUsage(totalBytes: 100, freeBytes: 0, scope: ""))
        XCTAssertEqual(full.usedPercentage, 100)
        var partial = container("partial", store: "disk6s2")
        partial.removeValue(forKey: "CapacityFree")
        XCTAssertNil(try StorageUsageParser.apfsUsage(from: plist(["Containers": [partial]]), diskID: "disk6"))
    }

    func testMountedFallbackExcludesEFIAPFSAndOtherDisks() throws {
        let data = try plist(["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk6", "Partitions": [
                ["DeviceIdentifier": "disk6s1", "Content": "EFI", "MountPoint": "/Volumes/EFI"],
                ["DeviceIdentifier": "disk6s2", "Content": "Microsoft Basic Data", "MountPoint": "/Volumes/Files"],
                ["DeviceIdentifier": "disk6s3", "Content": "Apple_APFS", "MountPoint": "/Volumes/APFS"]]],
            ["DeviceIdentifier": "disk7", "MountPoint": "/Volumes/Other"]
        ]])
        XCTAssertEqual(try StorageUsageParser.mountedNonAPFSPaths(from: data, diskID: "disk6"), ["/Volumes/Files"])
    }

    func testStorageServiceQueriesReadOnlyAPFSData() async throws {
        let runner = StorageRunner(data: try plist(["Containers": [container("a", store: "disk6s2")]]))
        let disk = PhysicalDisk(id: "disk6", name: "SSD", size: 1000, isInternal: false, connection: "USB", isSSD: true)
        let usage = try await DiskService(runner: runner).storageUsage(for: disk)
        XCTAssertEqual(usage?.usedPercentage, 75)
        let calls = await runner.calls
        XCTAssertEqual(calls, [["apfs", "list", "-plist"]])
    }
}

private actor StorageRunner: CommandRunning {
    let data: Data
    var calls: [[String]] = []
    init(data: Data) { self.data = data }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.append(arguments)
        return CommandResult(output: data)
    }
}
