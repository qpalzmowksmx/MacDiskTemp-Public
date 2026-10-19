import XCTest
import DiskCore
@testable import AlertCore

@MainActor final class MemoryStore: AlertStateStore {
    var document: AlertDocument?
    var fail = false
    var readFail = false
    func load() throws -> AlertDocument? {
        if readFail { throw AlertFailure("read failure") }; return document
    }
    func save(_ value: AlertDocument) throws {
        if fail { throw AlertFailure("disk full") }; document = value
    }
}
@MainActor final class TestClock: AlertClock {
    var now: Double = 100
    var timeout: CheckedContinuation<Void, Error>?
    var captureTimeout = false
    func sleep(seconds: Double) async throws {
        if captureTimeout { try await withCheckedThrowingContinuation { timeout = $0 } }
        else { try await Task.sleep(for: .seconds(3600)) }
    }
}
@MainActor final class FakeGateway: NotificationGateway {
    var value: AlertPermission = .allowed(sound: true)
    var sent: [AlertNotification] = []
    var canceled: [String] = []
    var requests = 0
    var failure: Error?
    var holdPermission = false
    var holdAdd = false
    var permissionContinuation: CheckedContinuation<AlertPermission, Error>?
    var addContinuation: CheckedContinuation<Void, Error>?
    var pending: [String] = []
    var delivered: [String] = []
    func permission() async throws -> AlertPermission {
        if holdPermission {
            holdPermission = false
            return try await withCheckedThrowingContinuation { permissionContinuation = $0 }
        }
        return value
    }
    func requestPermission() async throws -> AlertPermission { requests += 1; return value }
    func add(_ notification: AlertNotification) async throws {
        sent.append(notification)
        if holdAdd {
            holdAdd = false
            try await withCheckedThrowingContinuation { addContinuation = $0 }
        }
        if let failure { throw failure }
    }
    func cancel(_ ids: [String]) { canceled += ids }
    func pendingIDs() async -> [String] { pending }
    func deliveredIDs() async -> [String] { delivered }
}

@MainActor final class AlertTests: XCTestCase {
    var store: MemoryStore!
    var gateway: FakeGateway!
    var clock: TestClock!
    var coordinator: AlertCoordinator!
    var sequence: UInt64 = 0
    func setup(enabled: Bool = true) async throws {
        store = MemoryStore(); gateway = FakeGateway(); clock = TestClock()
        coordinator = AlertCoordinator(gateway: gateway, store: store, clock: clock)
        await coordinator.start()
        var draft = AlertDraft(coordinator.settings); draft.enabled = enabled
        try coordinator.save(draft)
        sequence = 0
    }
    func sample(_ temperature: Int?, device: String = "A", persistent: Bool = true, gap: Double = 325) {
        clock.now += 1; sequence += 1
        coordinator.receive(.init(device: device, persistent: persistent, context: coordinator.context,
            rule: coordinator.settings.rule, sequence: sequence, started: clock.now, completed: clock.now,
            temperature: temperature), maximumGap: gap)
    }
    func settle() async { for _ in 0..<100 { await Task.yield() } }
    func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 { if condition() { return }; await Task.yield() }
        XCTFail("Asynchronous event did not arrive", file: file, line: line)
    }

    func testThresholdAndCoolingI01I02() async throws {
        try await setup()
        for t in [70,71,70,71,72] { sample(t) }; await settle()
        XCTAssertEqual(gateway.sent.count, 1)
        for t in [80,69,68,69,68] { sample(t) }; await settle()
        XCTAssertEqual(gateway.sent.count, 1)
        for t in [68,71,72] { sample(t) }; await settle()
        XCTAssertEqual(gateway.sent.count, 2)
    }
    func testFailuresBreakStreakWithoutRearmingI03() async throws {
        try await setup(); sample(71); sample(nil); sample(72); await settle()
        XCTAssertTrue(gateway.sent.isEmpty)
        sample(72); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        coordinator.measurementFailed(); sample(80); sample(80); await settle()
        XCTAssertEqual(gateway.sent.count, 1)
    }
    func testDuplicateStaleAndPreviousRuleI04() async throws {
        try await setup(); sample(75)
        let event = AlertMeasurement(device: "A", context: coordinator.context, rule: coordinator.settings.rule,
            sequence: sequence, started: clock.now, completed: clock.now, temperature: 75)
        coordinator.receive(event, maximumGap: 60); await settle(); XCTAssertTrue(gateway.sent.isEmpty)
        sequence += 1
        clock.now += 31
        coordinator.receive(.init(device: "A", context: coordinator.context, rule: coordinator.settings.rule,
            sequence: sequence, started: clock.now - 31, completed: clock.now, temperature: 80), maximumGap: 60)
        sample(80); await settle(); XCTAssertTrue(gateway.sent.isEmpty)
        coordinator.invalidate(); coordinator.receive(event, maximumGap: 60); await settle()
        XCTAssertTrue(gateway.sent.isEmpty)
    }
    func testFiveMinuteSamplesAndLongGapI05() async throws {
        try await setup(); sample(75); clock.now += 300; sample(75); await settle()
        XCTAssertEqual(gateway.sent.count, 1)
        sample(68); sample(68); sample(75); clock.now += 326; sample(75); await settle()
        XCTAssertEqual(gateway.sent.count, 1)
    }
    func testCanceledDraftLeavesMonitoringActiveI06I11() async throws {
        try await setup(); let session = coordinator.openEditor(); await settle()
        let original = coordinator.settings
        var draft = AlertDraft(original); draft.enabled = false; draft.threshold = "1"; draft.smartctlPath = "other"
        coordinator.closeEditor(session)
        XCTAssertEqual(coordinator.settings, original)
        sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
    }
    func testValidationOffAndAtomicSaveFailureI07() async throws {
        try await setup()
        let original = coordinator.settings
        var draft = AlertDraft(original); draft.threshold = "NaN"
        XCTAssertThrowsError(try coordinator.save(draft))
        draft.enabled = false; try coordinator.save(draft)
        XCTAssertFalse(coordinator.settings.enabled); XCTAssertEqual(coordinator.settings.threshold, 70)
        let saved = coordinator.settings; draft.enabled = true; draft.threshold = "80"; store.fail = true
        XCTAssertThrowsError(try coordinator.save(draft)); XCTAssertEqual(coordinator.settings, saved)
        XCTAssertEqual(store.document?.settings, saved)
    }
    func testNoopSaveAndRuleChangesI08() async throws {
        try await setup(); sample(75); sample(75); await settle()
        let rule = coordinator.settings.rule
        XCTAssertFalse(try coordinator.save(AlertDraft(coordinator.settings)))
        sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        var draft = AlertDraft(coordinator.settings); draft.threshold = "71"; try coordinator.save(draft)
        XCTAssertNotEqual(coordinator.settings.rule, rule)
        sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 2)
    }
    func testDisableWhilePermissionWaitsI09() async throws {
        try await setup(); gateway.holdPermission = true; sample(75); sample(75)
        await until { gateway.permissionContinuation != nil }
        var draft = AlertDraft(coordinator.settings); draft.enabled = false; try coordinator.save(draft)
        gateway.permissionContinuation?.resume(returning: .allowed(sound: true)); gateway.permissionContinuation = nil
        await settle(); XCTAssertTrue(gateway.sent.isEmpty)
    }
    func testTestNotificationIsIndependentAndCancelsI10() async throws {
        try await setup(enabled: false)
        let session = coordinator.openEditor(); await settle()
        gateway.holdPermission = true
        coordinator.sendTest(session: session); coordinator.sendTest(session: session)
        await until { gateway.permissionContinuation != nil }
        coordinator.closeEditor(session)
        gateway.permissionContinuation?.resume(returning: .allowed(sound: true)); gateway.permissionContinuation = nil
        await settle(); XCTAssertTrue(gateway.sent.isEmpty); XCTAssertFalse(coordinator.settings.enabled)
        let second = coordinator.openEditor(); await settle(); coordinator.sendTest(session: second); await settle()
        XCTAssertEqual(gateway.sent.count, 1); XCTAssertTrue(store.document!.devices.isEmpty)
        XCTAssertFalse(coordinator.settings.enabled)
    }
    func testDiskSwitchAndReturnI12() async throws {
        try await setup(); sample(75); sample(75); await settle()
        coordinator.invalidate(); sample(75, device: "B"); sample(75, device: "B"); await settle()
        coordinator.invalidate(); sample(75); sample(75); await settle()
        XCTAssertEqual(gateway.sent.count, 2)
    }
    func testSessionIdentityDoesNotPersistI13() async throws {
        try await setup(); sample(75, persistent: false); sample(75, persistent: false); await settle()
        XCTAssertTrue(store.document!.devices.isEmpty); XCTAssertTrue(coordinator.identityLimited)
    }
    func testRestoreAcceptedAndUncertainIntentI15() async throws {
        try await setup(); sample(75); sample(75); await settle()
        coordinator = AlertCoordinator(gateway: gateway, store: store, clock: clock); await coordinator.start()
        sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        store.document!.devices["A"]!.outcome = .intent
        coordinator = AlertCoordinator(gateway: gateway, store: store, clock: clock); await coordinator.start()
        sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        XCTAssertEqual(store.document!.devices["A"]?.outcome, .uncertain)
        sample(68); sample(68); sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 2)
    }
    func testRetryUsesNewSampleAndBoundedBudgetI16I17() async throws {
        try await setup(); gateway.failure = AlertFailure("temporarily unavailable", retryable: true)
        sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        clock.now += 30; await settle(); XCTAssertEqual(gateway.sent.count, 1)
        sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 2)
        clock.now += 120; sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 3)
        clock.now += 1000; sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 3)
        coordinator = AlertCoordinator(gateway: gateway, store: store, clock: clock); await coordinator.start()
        clock.now += 200; sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 3)
    }
    func testSleepOrIntervalInterruptsStreakI18() async throws {
        try await setup(); sample(75); coordinator.invalidate(); sample(75); await settle()
        XCTAssertTrue(gateway.sent.isEmpty)
        sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        coordinator.invalidate(); sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
    }
    func testLateAddCannotOverwriteNewRuleI19() async throws {
        try await setup(); gateway.holdAdd = true; sample(75); sample(75)
        await until { gateway.addContinuation != nil }
        let oldID = gateway.sent[0].id
        var draft = AlertDraft(coordinator.settings); draft.threshold = "72"; try coordinator.save(draft)
        sample(80); sample(80); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        gateway.addContinuation?.resume(); gateway.addContinuation = nil; await settle()
        sample(80); await settle(); XCTAssertEqual(gateway.sent.count, 2)
        XCTAssertTrue(gateway.canceled.contains(oldID))
        XCTAssertFalse(gateway.canceled.contains(gateway.sent[1].id))
        XCTAssertEqual(store.document!.devices["A"]?.rule, coordinator.settings.rule)
    }
    func testCancelSubmittedEpisodeDoesNotResendI19() async throws {
        try await setup(); gateway.holdAdd = true; sample(75); sample(75)
        await until { gateway.addContinuation != nil }
        sample(nil)
        gateway.addContinuation?.resume(); gateway.addContinuation = nil; await settle()
        sample(80); sample(80); await settle(); XCTAssertEqual(gateway.sent.count, 1)
    }
    func testSuccessThenDiskFullDoesNotDuplicateI20() async throws {
        try await setup(); gateway.holdAdd = true; sample(75); sample(75)
        await until { gateway.addContinuation != nil }; store.fail = true
        gateway.addContinuation?.resume(); gateway.addContinuation = nil; await settle()
        XCTAssertNotNil(coordinator.storageError)
        sample(80); sample(80); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        store.fail = false; sample(80); sample(80); await settle()
        XCTAssertEqual(gateway.sent.count, 1); XCTAssertEqual(store.document!.devices["A"]?.outcome, .accepted)
    }
    func testDeniedAndLimitedNeverLatchI21() async throws {
        try await setup(); gateway.value = .denied; await coordinator.refreshPermission()
        sample(75); sample(75); await settle(); XCTAssertTrue(gateway.sent.isEmpty)
        XCTAssertEqual(gateway.requests, 0)
        gateway.value = .limited; await coordinator.refreshPermission(); sample(75); sample(75); await settle()
        XCTAssertTrue(gateway.sent.isEmpty)
        gateway.value = .allowed(sound: false); await coordinator.refreshPermission()
        sample(75); await settle(); XCTAssertTrue(gateway.sent.isEmpty)
        sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1); XCTAssertFalse(gateway.sent[0].sound)
    }
    func testReadFailureDoesNotOverwriteFile() async throws {
        let store = MemoryStore(); store.readFail = true
        let coordinator = AlertCoordinator(gateway: FakeGateway(), store: store, clock: TestClock())
        await coordinator.start()
        XCTAssertNotNil(coordinator.storageError); XCTAssertNil(store.document)
        XCTAssertThrowsError(try coordinator.save(AlertDraft(coordinator.settings)))
    }
    func testAtomicFileRoundTripAndCorruption() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("alerts.json"); let store = FileAlertStore(url: url)
        XCTAssertNil(try store.load())
        var document = AlertDocument(); document.settings.enabled = true
        try store.save(document); XCTAssertEqual(try store.load(), document)
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try String(contentsOf: url), "broken")
    }
    func testPermissionDelayCannotUseOldOrCooledSample() async throws {
        try await setup(); gateway.holdPermission = true; sample(75); sample(75)
        await until { gateway.permissionContinuation != nil }
        clock.now += 31
        gateway.permissionContinuation?.resume(returning: .allowed(sound: true)); gateway.permissionContinuation = nil
        await settle(); XCTAssertTrue(gateway.sent.isEmpty)
        gateway.holdPermission = true; sample(75)
        await until { gateway.permissionContinuation != nil }; sample(69)
        gateway.permissionContinuation?.resume(returning: .allowed(sound: true)); gateway.permissionContinuation = nil
        await settle(); XCTAssertTrue(gateway.sent.isEmpty)
    }
    func testTimeoutKeepsSlotAndDoesNotRetry() async throws {
        try await setup(); clock.captureTimeout = true; gateway.holdAdd = true
        sample(75); sample(75)
        await until { clock.timeout != nil && gateway.addContinuation != nil }
        clock.timeout?.resume(); clock.timeout = nil; await settle()
        sample(80); sample(80); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        gateway.addContinuation?.resume(); gateway.addContinuation = nil; await settle()
        sample(80); sample(80); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        XCTAssertEqual(store.document?.devices["A"]?.outcome, .uncertain)
    }
    func testCoolingSaveFailureCannotRearm() async throws {
        try await setup(); sample(75); sample(75); await settle()
        sample(68); store.fail = true; sample(68)
        XCTAssertNotNil(coordinator.storageError)
        store.fail = false; sample(75); sample(75); await settle()
        XCTAssertEqual(gateway.sent.count, 1)
    }
    func testIntentSaveFailurePreventsOSCall() async throws {
        try await setup(); sample(75); gateway.holdPermission = true; sample(75)
        await until { gateway.permissionContinuation != nil }; store.fail = true
        gateway.permissionContinuation?.resume(returning: .allowed(sound: true)); gateway.permissionContinuation = nil
        await settle(); XCTAssertTrue(gateway.sent.isEmpty)
    }
    func testNonRetryableFailureExhaustsEpisode() async throws {
        try await setup(); gateway.failure = AlertFailure("unsupported")
        sample(75); sample(75); await settle(); clock.now += 150
        sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
    }
    func testStartupCancelsOldPendingAndRecoversDeliveredIntent() async throws {
        try await setup()
        var record = AlertEpisode(rule: coordinator.settings.rule); record.id = UUID()
        record.outcome = .intent; record.requestID = "MacDiskTemp.thermal.old"
        store.document!.devices["A"] = record
        gateway.pending = ["MacDiskTemp.test.old", "unrelated"]
        gateway.delivered = [record.requestID!]
        coordinator = AlertCoordinator(gateway: gateway, store: store, clock: clock); await coordinator.start()
        XCTAssertTrue(gateway.canceled.contains("MacDiskTemp.test.old")); XCTAssertFalse(gateway.canceled.contains("unrelated"))
        sample(75); sample(75); await settle(); XCTAssertTrue(gateway.sent.isEmpty)
        XCTAssertEqual(store.document!.devices["A"]?.outcome, .accepted)
    }
    func testUnsupportedSchemaPreservesFileAndBlocksMonitoring() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("alerts.json")
        var document = AlertDocument(); document.schema = 999; document.settings.enabled = true
        let bytes = try JSONEncoder().encode(document)
        try bytes.write(to: url)
        let gateway = FakeGateway()
        let coordinator = AlertCoordinator(gateway: gateway, store: FileAlertStore(url: url), clock: TestClock())
        await coordinator.start()
        XCTAssertNotNil(coordinator.storageError)
        XCTAssertThrowsError(try coordinator.save(AlertDraft(coordinator.settings)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(gateway.sent.isEmpty)
    }
    func testMissingTemperatureNeverBecomesZeroAndPartialHealthIsIndependent() async throws {
        try await setup(); sample(75); sample(1001); sample(75); await settle()
        XCTAssertTrue(gateway.sent.isEmpty)
        sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
        sample(nil); sample(nil); sample(75); sample(75); await settle(); XCTAssertEqual(gateway.sent.count, 1)
    }
}
