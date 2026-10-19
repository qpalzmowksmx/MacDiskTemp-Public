import Foundation
import DiskCore

public struct AlertSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var threshold = TemperatureAlertPolicy.defaultThreshold
    public var rule = UUID()
    public var smartctlPath = ""
    public init() {}
}

public struct AlertDraft: Equatable {
    public var enabled: Bool
    public var threshold: String
    public var smartctlPath: String
    public init(_ settings: AlertSettings) {
        enabled = settings.enabled; threshold = String(settings.threshold); smartctlPath = settings.smartctlPath
    }
    public func validated(previous: AlertSettings) throws -> AlertSettings {
        let value = Int(threshold.trimmingCharacters(in: .whitespacesAndNewlines))
        if enabled && (value == nil || !TemperatureAlertPolicy.thresholdRange.contains(value!)) {
            throw AlertFailure("기준 온도는 1~150°C의 정수로 입력하세요.")
        }
        var next = previous
        next.enabled = enabled
        next.threshold = value.flatMap { TemperatureAlertPolicy.thresholdRange.contains($0) ? $0 : nil } ?? previous.threshold
        next.smartctlPath = smartctlPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.threshold != previous.threshold || (enabled && !previous.enabled) { next.rule = UUID() }
        return next
    }
}

public struct AlertDocument: Codable, Equatable {
    public var schema = 1
    public var settings = AlertSettings()
    public var devices: [String: AlertEpisode] = [:]
    public init() {}
    public func validate() throws {
        guard schema == 1, TemperatureAlertPolicy.thresholdRange.contains(settings.threshold),
              devices.values.allSatisfy({ (0...TemperatureAlertPolicy.maximumAttempts).contains($0.failures) &&
                  ($0.id != nil || ($0.outcome == .ready && $0.failures == 0 && $0.requestID == nil)) &&
                  ($0.outcome != .intent || $0.requestID != nil) }) else {
            throw AlertFailure("알림 저장 파일의 버전 또는 내용이 올바르지 않습니다. 기존 파일을 보존했습니다.")
        }
    }
}

public struct AlertFailure: LocalizedError {
    public let message: String
    public let retryable: Bool
    public init(_ message: String, retryable: Bool = false) { self.message = message; self.retryable = retryable }
    public var errorDescription: String? { message }
}

public enum AlertPermission: Equatable, Sendable {
    case notDetermined, denied, limited, allowed(sound: Bool)
    public var canSend: Bool { if case .allowed = self { return true }; return false }
    public var title: String {
        switch self {
        case .notDetermined: return "알림 권한이 필요합니다"
        case .denied: return "알림 권한이 거부되었습니다. 시스템 설정 → 알림에서 허용하세요"
        case .limited: return "배너 표시가 제한되어 있습니다. 시스템 설정 → 알림을 확인하세요"
        case .allowed(let sound): return sound ? "알림 허용됨" : "알림 허용됨 · 소리 꺼짐"
        }
    }
}

public struct AlertNotification: Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let sound: Bool
    public init(id: String, title: String, body: String, sound: Bool) {
        self.id = id; self.title = title; self.body = body; self.sound = sound
    }
}

@MainActor public protocol NotificationGateway: AnyObject {
    func permission() async throws -> AlertPermission
    func requestPermission() async throws -> AlertPermission
    func add(_ notification: AlertNotification) async throws
    func cancel(_ ids: [String])
    func pendingIDs() async -> [String]
    func deliveredIDs() async -> [String]
}

@MainActor public protocol AlertClock {
    var now: Double { get }
    func sleep(seconds: Double) async throws
}

@MainActor public struct ContinuousAlertClock: AlertClock {
    private let origin = ContinuousClock.now
    public init() {}
    public var now: Double {
        let value = origin.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

public struct AlertMeasurement {
    public let device: String
    public let persistent: Bool
    public let name: String
    public let context: UUID
    public let rule: UUID
    public let sequence: UInt64
    public let started: Double
    public let completed: Double
    public let date: Date
    public let temperature: Int?
    public init(device: String, persistent: Bool = true, name: String = "디스크", context: UUID,
                rule: UUID, sequence: UInt64, started: Double, completed: Double, date: Date = Date(), temperature: Int?) {
        self.device = device; self.persistent = persistent; self.name = name; self.context = context
        self.rule = rule; self.sequence = sequence; self.started = started; self.completed = completed
        self.date = date; self.temperature = temperature
    }
}
