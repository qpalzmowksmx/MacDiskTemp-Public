import Foundation

public enum TemperatureAlertPolicy {
    public static let defaultThreshold = 70
    public static let thresholdRange = 1...150
    public static let confirmations = 2
    public static let coolingDifference = 2
    public static let sampleLifetime: Double = 30
    public static let requestTimeout: Double = 10
    public static let maximumAttempts = 3
    public static func validTemperature(_ value: Int) -> Bool { (-273...1000).contains(value) }
    public static func retryDelay(failures: Int) -> Double { failures == 0 ? 0 : failures == 1 ? 30 : 120 }
    public static func maximumGap(interval: Int) -> Double { interval > 0 ? Double(interval) + 25 : 60 }
}

public struct AlertEpisode: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case ready, intent, accepted, uncertain }
    public var rule: UUID
    public var id: UUID?
    public var outcome: Outcome = .ready
    public var failures = 0
    public var requestID: String?
    public init(rule: UUID) { self.rule = rule }
}

/// Pure transition logic. Delivery and persistence belong to the coordinator.
public struct TemperatureAlertEvaluator: Sendable {
    public enum Decision: Equatable { case ignored, hold, candidate, cooled }
    public var episode: AlertEpisode
    public private(set) var highCount = 0
    private var lowCount = 0
    private var lastSequence: UInt64 = 0
    private var lastCompleted: Double?
    public init(episode: AlertEpisode) { self.episode = episode }

    public mutating func interrupt() {
        highCount = 0; lowCount = 0; lastCompleted = nil
    }

    public mutating func consume(sequence: UInt64, temperature: Int?, started: Double,
                                 completed: Double, now: Double, maximumGap: Double,
                                 threshold: Int) -> Decision {
        guard sequence > lastSequence else { return .ignored }
        lastSequence = sequence
        guard let temperature, TemperatureAlertPolicy.validTemperature(temperature),
              started <= completed, completed <= now, now - started <= TemperatureAlertPolicy.sampleLifetime else {
            interrupt(); return .hold
        }
        if let lastCompleted, completed - lastCompleted > maximumGap || completed < lastCompleted {
            interrupt()
        }
        lastCompleted = completed
        if temperature > threshold {
            lowCount = 0; highCount = min(TemperatureAlertPolicy.confirmations, highCount + 1)
            if highCount == TemperatureAlertPolicy.confirmations {
                if episode.id == nil { episode.id = UUID() }
                if episode.outcome == .ready && episode.failures < TemperatureAlertPolicy.maximumAttempts { return .candidate }
            }
        } else if temperature <= threshold - TemperatureAlertPolicy.coolingDifference {
            highCount = 0; lowCount = min(TemperatureAlertPolicy.confirmations, lowCount + 1)
            if lowCount == TemperatureAlertPolicy.confirmations, episode.id != nil {
                episode = AlertEpisode(rule: episode.rule)
                return .cooled
            }
        } else {
            highCount = 0; lowCount = 0
        }
        return .hold
    }
}
