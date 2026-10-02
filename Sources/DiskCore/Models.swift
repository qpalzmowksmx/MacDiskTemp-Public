import Foundation

public struct PhysicalDisk: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let size: Int64
    public let isInternal: Bool?
    public let connection: String
    public let isSSD: Bool?
    public let identity: String

    public var path: String { "/dev/\(id)" }
    public var location: String { isInternal.map { $0 ? "내장" : "외장" } ?? "위치 미확인" }
    public var capacity: String { DisplayFormat.bytes(Double(size)) }

    public init(id: String, name: String, size: Int64, isInternal: Bool?, connection: String,
                isSSD: Bool?, identity: String? = nil) {
        self.id = id; self.name = name; self.size = size; self.isInternal = isInternal
        self.connection = connection; self.isSSD = isSSD
        self.identity = identity ?? "\(id):\(name):\(size)"
    }
}

public enum DiskHealth: String, Sendable {
    case healthy, warning, failing, unknown
    public var title: String {
        switch self {
        case .healthy: return "정상"
        case .warning: return "확인 필요"
        case .failing: return "위험"
        case .unknown: return "확인 불가"
        }
    }
}

public struct SMARTMetric: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public let note: String
    public let symbol: String
    public init(_ id: String, _ title: String, _ value: String, _ note: String, _ symbol: String) {
        self.id = id; self.title = title; self.value = value; self.note = note; self.symbol = symbol
    }
}

public struct SMARTSnapshot: Sendable {
    public let date: Date
    public let model: String
    public let serial: String
    public let firmware: String
    public let protocolName: String
    public let temperature: Int?
    public let warningTemperature: Int?
    public let criticalTemperature: Int?
    public let warningTemperatureMinutes: Double?
    public let criticalTemperatureMinutes: Double?
    public let sensors: [Int]
    public let passed: Bool?
    public let health: DiskHealth
    public let warnings: [String]
    public let percentageUsed: Int?
    public let availableSpare: Int?
    public let bytesRead: Double?
    public let bytesWritten: Double?
    public let powerOnHours: Double?
    public let metrics: [SMARTMetric]
    public let rawText: String
    public let rawJSON: String
    public let exitStatus: Int

    public var temperatureText: String { temperature.map { "\($0)°C" } ?? "—" }
    public var healthExplanation: String {
        if let first = warnings.first { return first }
        switch passed {
        case true: return "디스크의 SMART 자체 평가를 통과했습니다."
        case false: return "디스크의 SMART 자체 평가에서 문제가 감지되었습니다."
        case nil: return "이 장치가 SMART 종합 판정을 제공하지 않습니다."
        }
    }
}

public struct DiskError: LocalizedError, Sendable {
    public let title: String
    public let message: String
    public let details: String
    public var errorDescription: String? { message }
    public init(_ title: String, _ message: String, details: String = "") {
        self.title = title; self.message = message; self.details = details
    }

    public static let missingTool = DiskError("smartmontools 설치가 필요합니다",
        "자동 설치로 필요한 도구를 준비하세요. 이미 설치했다면 설정에서 smartctl 파일을 선택하세요.")

    public static func smartFailure(_ output: String) -> DiskError {
        let lower = output.lowercased()
        if lower.contains("permission") || lower.contains("operation not permitted") || lower.contains("must be root") {
            return DiskError("디스크 접근 권한이 필요합니다",
                "이 장치는 현재 권한으로 SMART 정보를 읽을 수 없습니다. macOS 개인정보 보호 설정과 장치 접근 권한을 확인하세요. 관리자 권한이 필요한 장치는 이 버전에서 직접 조회할 수 없습니다.", details: output)
        }
        return DiskError("SMART 정보를 읽을 수 없습니다",
            "디스크가 연결되어 있는지 확인하세요. 일부 USB 케이스와 장치는 macOS에서 SMART 전달을 지원하지 않습니다.", details: output)
    }
}

public enum DisplayFormat {
    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var amount = value
        var index = 0
        while abs(amount) >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
        return "\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(units[index])"
    }
    public static func count(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
    }
}
