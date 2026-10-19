import Foundation
import Combine
import DiskCore

/// All state and small file transactions are serialized on the main actor.
/// Each suspended OS operation retains its own slot until its actual completion.
@MainActor public final class AlertCoordinator: ObservableObject {
    @Published public private(set) var settings = AlertSettings()
    @Published public private(set) var permission: AlertPermission?
    @Published public private(set) var message = ""
    @Published public private(set) var storageError: String?
    @Published public private(set) var testBusy = false
    @Published public private(set) var ready = false
    @Published public private(set) var identityLimited = false
    public private(set) var context = UUID()
    public var now: Double { clock.now }

    private struct DeviceState {
        var evaluator: TemperatureAlertEvaluator
        var persistent: Bool
        var latest: AlertMeasurement?
        var retryAfter: Double = 0
    }
    private final class Operation {
        let id = UUID()
        let requestID: String
        let context: UUID
        let rule: UUID
        let episode: UUID?
        var valid = true
        var submitted = false
        init(context: UUID, rule: UUID, episode: UUID?, test: Bool = false) {
            self.context = context; self.rule = rule; self.episode = episode
            requestID = "MacDiskTemp.\(test ? "test" : "thermal").\(rule).\(episode ?? UUID()).\(id)"
        }
    }
    private let gateway: any NotificationGateway
    private let store: any AlertStateStore
    private let clock: any AlertClock
    private var document = AlertDocument()
    private var loadFailed = false
    private var activationTime: Double = 0
    private var states: [String: DeviceState] = [:]
    private var operations: [String: Operation] = [:]
    private var activeDevice: String?
    private var editor: UUID?
    private var testOperation: Operation?
    private var permissionRequest: Task<AlertPermission, Error>?
    private var permissionRevision = 0

    public init(gateway: any NotificationGateway, store: any AlertStateStore,
                clock: any AlertClock, legacyPath: String = "") {
        self.gateway = gateway; self.store = store; self.clock = clock
        do {
            if let saved = try store.load() { document = saved }
            else { document.settings.smartctlPath = legacyPath; try store.save(document) }
            settings = document.settings
        } catch {
            loadFailed = true
            settings.smartctlPath = legacyPath
            storageError = "알림 저장소를 읽을 수 없습니다. 기존 파일을 보존했습니다: \(error.localizedDescription)"
        }
        activationTime = clock.now
    }

    public func start() async {
        guard !ready else { return }
        // No sends are permitted before stale pending requests have been removed.
        let pending = await gateway.pendingIDs()
        gateway.cancel(pending.filter { $0.hasPrefix("MacDiskTemp.") })
        let delivered = Set(await gateway.deliveredIDs())
        for (key, var episode) in document.devices where episode.outcome == .intent {
            episode.outcome = episode.requestID.map { delivered.contains($0) } == true ? .accepted : .uncertain
            document.devices[key] = episode
        }
        if !loadFailed { _ = flush() }
        await refreshPermission()
        ready = true
    }

    public func openEditor() -> UUID {
        closeEditor()
        let id = UUID(); editor = id
        Task { await refreshPermission() }
        return id
    }
    public func closeEditor(_ session: UUID? = nil) {
        guard session == nil || session == editor else { return }
        editor = nil; cancelTest()
    }

    /// Returns whether the settings actually changed. No-op saves preserve the episode.
    @discardableResult public func save(_ draft: AlertDraft) throws -> Bool {
        let next = try draft.validated(previous: settings)
        guard !loadFailed else { throw AlertFailure(storageError ?? "저장소를 읽을 수 없습니다.") }
        if storageError != nil, !flush() { throw AlertFailure(storageError!) }
        cancelTest()
        guard next != settings else { message = "설정이 저장되어 있습니다."; return false }
        invalidate()
        var candidate = document
        candidate.settings = next
        if next.rule != settings.rule { candidate.devices = [:] }
        else { mergeStates(into: &candidate) }
        do { try store.save(candidate) }
        catch {
            storageError = "설정이 저장되지 않았습니다: \(error.localizedDescription)"
            throw AlertFailure(storageError!)
        }
        if next.rule != settings.rule { states = [:] }
        settings = next; document = candidate; storageError = nil
        message = next.enabled ? "설정이 저장되었습니다. \(permission?.title ?? "권한 확인 중")" : "설정이 저장되었습니다. 온도 알림이 꺼져 있습니다."
        return true
    }

    public func requestSavedPermission(session: UUID) async {
        guard editor == session, settings.enabled, ready else { return }
        let generation = context
        do {
            let value = try await obtainPermission(prompt: true)
            guard editor == session, context == generation, settings.enabled else { return }
            applyPermission(value)
            message = "설정이 저장되었습니다. \(value.title)"
        } catch {
            guard editor == session, context == generation else { return }
            message = "설정은 저장됐지만 권한 확인에 실패했습니다: \(error.localizedDescription)"
        }
    }

    public func refreshPermission() async {
        permissionRevision += 1
        let revision = permissionRevision
        do {
            let value = try await gateway.permission()
            guard revision == permissionRevision else { return }
            applyPermission(value)
        } catch {
            guard revision == permissionRevision else { return }
            message = "알림 권한 확인 실패: \(error.localizedDescription)"
        }
    }

    private func obtainPermission(prompt: Bool) async throws -> AlertPermission {
        let value = try await gateway.permission()
        guard prompt, value == .notDetermined else { return value }
        if let permissionRequest { return try await permissionRequest.value }
        let task = Task { try await gateway.requestPermission() }
        permissionRequest = task
        defer { permissionRequest = nil }
        return try await task.value
    }

    private func applyPermission(_ value: AlertPermission) {
        permissionRevision += 1
        let changedAvailability = permission != nil && permission?.canSend != value.canSend
        if let permission, permission != value {
            message = value.canSend ? "알림 권한이 허용되었습니다. 새 측정부터 판단합니다." : value.title
        }
        permission = value
        if changedAvailability {
            for key in Array(states.keys) {
                cancelOperation(key)
                states[key]?.evaluator.interrupt(); states[key]?.latest = nil
            }
        }
    }

    /// Selection, connection generation, sleep, tool path and interval changes.
    public func invalidate() {
        context = UUID(); activationTime = clock.now
        gateway.cancel(states.values.compactMap { $0.evaluator.episode.requestID })
        for key in Array(operations.keys) { cancelOperation(key) }
        for key in Array(states.keys) { states[key]?.evaluator.interrupt(); states[key]?.latest = nil }
        activeDevice = nil
    }

    public func measurementFailed() {
        if let activeDevice {
            cancelOperation(activeDevice)
            states[activeDevice]?.evaluator.interrupt(); states[activeDevice]?.latest = nil
        }
    }

    public func receive(_ sample: AlertMeasurement, maximumGap: Double) {
        guard ready, !loadFailed, settings.enabled, sample.context == context,
              sample.rule == settings.rule, sample.started >= activationTime else { return }
        if storageError != nil, !flush() { return }
        if activeDevice != sample.device {
            if let activeDevice { cancelOperation(activeDevice); states[activeDevice]?.evaluator.interrupt() }
            activeDevice = sample.device
        }
        identityLimited = !sample.persistent
        if states[sample.device] == nil {
            let saved = sample.persistent ? document.devices[sample.device] : nil
            var episode = saved?.rule == settings.rule ? saved! : AlertEpisode(rule: settings.rule)
            if episode.outcome == .intent { episode.outcome = .uncertain }
            let delay: Double = TemperatureAlertPolicy.retryDelay(failures: episode.failures)
            states[sample.device] = DeviceState(evaluator: .init(episode: episode), persistent: sample.persistent,
                                               retryAfter: clock.now + delay)
            if episode.outcome == .uncertain {
                message = "이전 알림의 접수 결과가 불명확해 재전송을 보류합니다. 냉각을 2회 확인하거나 알림 기준을 새로 저장하면 다시 판단합니다."
            } else if episode.outcome == .accepted {
                message = "이 과열 구간은 이미 알림을 요청했습니다. 냉각을 2회 확인할 때까지 중복 알림을 보내지 않습니다."
            } else if episode.failures >= TemperatureAlertPolicy.maximumAttempts {
                message = "이번 과열 구간의 알림 재시도 한도를 소진했습니다. 냉각 후 다시 판단합니다."
            }
        }
        var state = states[sample.device]!
        let decision = state.evaluator.consume(sequence: sample.sequence, temperature: sample.temperature,
            started: sample.started, completed: sample.completed, now: clock.now, maximumGap: maximumGap,
            threshold: settings.threshold)
        guard decision != .ignored else { return }
        if decision == .cooled {
            let old = states[sample.device]!
            if let requestID = old.evaluator.episode.requestID { gateway.cancel([requestID]) }
            cancelOperation(sample.device)
            state.retryAfter = 0; state.latest = sample
            states[sample.device] = state
            if !flush() { states[sample.device] = old; states[sample.device]?.evaluator.interrupt() }
            else { message = "냉각을 확인했습니다. 다음 과열부터 다시 알립니다." }
            return
        }
        state.latest = sample
        states[sample.device] = state
        if sample.temperature == nil || sample.temperature! <= settings.threshold ||
            clock.now - sample.started > TemperatureAlertPolicy.sampleLifetime || state.evaluator.highCount < TemperatureAlertPolicy.confirmations {
            cancelOperation(sample.device)
        }
        guard decision == .candidate, sample.started >= state.retryAfter,
              operations[sample.device] == nil else { return }
        let operation = Operation(context: context, rule: settings.rule, episode: state.evaluator.episode.id)
        operations[sample.device] = operation
        Task { await sendAutomatic(device: sample.device, operation: operation) }
    }

    private func eligible(_ key: String, _ operation: Operation) -> AlertMeasurement? {
        guard operation.valid, operation.context == context, operation.rule == settings.rule, settings.enabled,
              activeDevice == key, storageError == nil, let state = states[key],
              state.evaluator.episode.id == operation.episode, state.evaluator.highCount >= TemperatureAlertPolicy.confirmations,
              let sample = state.latest, let temperature = sample.temperature, temperature > settings.threshold,
              TemperatureAlertPolicy.validTemperature(temperature), clock.now >= sample.completed,
              clock.now - sample.started <= TemperatureAlertPolicy.sampleLifetime, sample.started >= state.retryAfter else { return nil }
        return sample
    }

    private func sendAutomatic(device: String, operation: Operation) async {
        defer { if operations[device]?.id == operation.id { operations[device] = nil } }
        do {
            let value = try await obtainPermission(prompt: false)
            guard eligible(device, operation) != nil else { return }
            applyPermission(value)
            guard value.canSend, let sample = eligible(device, operation) else {
                if operation.valid { message = value.title }
                return
            }
            states[device]?.evaluator.episode.outcome = .intent
            states[device]?.evaluator.episode.requestID = operation.requestID
            guard flush() else {
                states[device]?.evaluator.episode.outcome = .ready
                states[device]?.evaluator.episode.requestID = nil
                return
            }
            guard eligible(device, operation) != nil else { return }
            operation.submitted = true
            let watchdog = watch(operation, device: device)
            defer { watchdog.cancel() }
            let sound: Bool
            if case .allowed(let enabled) = value { sound = enabled } else { sound = false }
            try await gateway.add(.init(id: operation.requestID, title: "디스크 온도 주의",
                body: "\(sample.name): 측정 당시 \(sample.temperature!)°C (기준 \(settings.threshold)°C 초과)\n\(sample.date.formatted(date: .omitted, time: .standard)) 측정",
                sound: sound))
            guard operation.valid, context == operation.context, settings.rule == operation.rule else {
                gateway.cancel([operation.requestID]); return
            }
            states[device]?.evaluator.episode.outcome = .accepted
            _ = flush()
            message = "macOS에 온도 알림을 요청했습니다. 냉각 전까지 중복 알림을 보내지 않습니다."
        } catch {
            guard operation.valid, context == operation.context, settings.rule == operation.rule else {
                gateway.cancel([operation.requestID]); return
            }
            let retryable = (error as? AlertFailure)?.retryable ?? true
            states[device]?.evaluator.episode.outcome = .ready
            states[device]?.evaluator.episode.requestID = nil
            let count = min(TemperatureAlertPolicy.maximumAttempts, (states[device]?.evaluator.episode.failures ?? 0) + 1)
            states[device]?.evaluator.episode.failures = retryable ? count : TemperatureAlertPolicy.maximumAttempts
            states[device]?.retryAfter = clock.now + TemperatureAlertPolicy.retryDelay(failures: count)
            _ = flush()
            message = "알림 요청 실패: \(error.localizedDescription)" + (count < TemperatureAlertPolicy.maximumAttempts && retryable ? " · 대기 후 새 측정에서 재시도합니다." : " · 이번 과열 구간의 재시도를 중지했습니다.")
        }
    }

    private func watch(_ operation: Operation, device: String?) -> Task<Void, Never> {
        Task {
            do { try await clock.sleep(seconds: TemperatureAlertPolicy.requestTimeout) } catch { return }
            guard operation.valid else { return }
            operation.valid = false
            gateway.cancel([operation.requestID])
            if let device, states[device]?.evaluator.episode.id == operation.episode {
                states[device]?.evaluator.episode.outcome = .uncertain
                _ = flush()
            }
            message = "알림 접수 결과를 확인할 수 없어 재전송을 보류합니다."
        }
    }

    private func cancelOperation(_ key: String) {
        guard let operation = operations[key] else { return }
        operation.valid = false
        gateway.cancel([operation.requestID])
        if operation.submitted, states[key]?.evaluator.episode.id == operation.episode {
            states[key]?.evaluator.episode.outcome = .uncertain
            // The durable intent already protects against duplicates after a crash.
        }
    }

    public func sendTest(session: UUID) {
        guard editor == session, ready, testOperation == nil else { return }
        let operation = Operation(context: context, rule: settings.rule, episode: nil, test: true)
        testOperation = operation; testBusy = true
        Task {
            defer {
                if testOperation?.id == operation.id { testOperation = nil; testBusy = false }
            }
            do {
                let value = try await obtainPermission(prompt: true)
                guard operation.valid, editor == session else { return }
                applyPermission(value)
                guard case .allowed(let sound) = value else { message = value.title; return }
                operation.submitted = true
                let watchdog = watch(operation, device: nil)
                defer { watchdog.cancel() }
                try await gateway.add(.init(id: operation.requestID, title: "MacDiskTemp 시험 알림",
                    body: "시험 알림입니다. 실제 디스크 온도와 관계없이 전송했습니다.", sound: sound))
                guard operation.valid, editor == session else { gateway.cancel([operation.requestID]); return }
                message = "macOS에 시험 알림을 요청했습니다. 보이지 않으면 알림 설정과 집중 모드를 확인하세요."
            } catch {
                guard operation.valid, editor == session else { return }
                message = "시험 알림 실패: \(error.localizedDescription)"
            }
        }
    }

    private func cancelTest() {
        guard let operation = testOperation else { return }
        operation.valid = false
        gateway.cancel([operation.requestID])
    }

    private func mergeStates(into candidate: inout AlertDocument) {
        for (key, state) in states where state.persistent && state.evaluator.episode.rule == candidate.settings.rule {
            candidate.devices[key] = state.evaluator.episode
        }
    }
    @discardableResult private func flush() -> Bool {
        guard !loadFailed else { return false }
        var candidate = document
        mergeStates(into: &candidate)
        do { try store.save(candidate); document = candidate; storageError = nil; return true }
        catch { storageError = "알림 기록 저장 실패: \(error.localizedDescription)"; return false }
    }
}
