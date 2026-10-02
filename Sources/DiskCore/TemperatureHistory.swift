import CryptoKit
import Foundation

public struct TemperatureSummary: Equatable, Sendable {
    public private(set) var sampleCount: Int
    public private(set) var temperatureSum: Double
    public private(set) var maximum: Int
    public private(set) var maximumDate: Date
    public let firstDate: Date
    public private(set) var lastDate: Date
    public private(set) var measuredDuration: TimeInterval

    public var average: Double { temperatureSum / Double(sampleCount) }

    fileprivate init(temperature: Int, date: Date) {
        sampleCount = 1; temperatureSum = Double(temperature); maximum = temperature
        maximumDate = date; firstDate = date; lastDate = date; measuredDuration = 0
    }

    fileprivate mutating func add(_ temperature: Int, date: Date, duration: TimeInterval) {
        sampleCount += 1
        temperatureSum += Double(temperature)
        if temperature > maximum { maximum = temperature; maximumDate = date }
        lastDate = date
        measuredDuration += duration
    }

}

/// In-memory aggregates for the current app run, separated by physical device.
public struct TemperatureHistory: Sendable {
    private var summaries: [String: TemperatureSummary] = [:]
    private var previous: (key: String, uptime: TimeInterval)?

    public init() {}

    public static func key(model: String, serial: String, fallback: String) -> String {
        let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serial.isEmpty, !["—", "unknown", "n/a"].contains(serial.lowercased()) else {
            // Missing serial numbers fall back to the current connection's identity.
            return "session:" + fallback
        }
        let data = Data("\(model)\u{0}\(serial)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func summary(for key: String) -> TemperatureSummary? { summaries[key] }

    @discardableResult
    public mutating func record(_ temperature: Int?, for key: String, date: Date,
                                uptime: TimeInterval, maximumGap: TimeInterval) -> TemperatureSummary? {
        guard let temperature, (-273...1000).contains(temperature) else {
            pause()
            return summaries[key]
        }
        var duration: TimeInterval = 0
        if let previous, previous.key == key {
            let gap = uptime - previous.uptime
            if gap > 0 && gap <= maximumGap { duration = gap }
        }
        if var summary = summaries[key] {
            summary.add(temperature, date: date, duration: duration)
            summaries[key] = summary
        } else {
            summaries[key] = TemperatureSummary(temperature: temperature, date: date)
        }
        previous = (key, uptime)
        return summaries[key]
    }

    public mutating func pause() { previous = nil }

}
