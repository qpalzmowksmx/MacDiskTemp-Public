import Foundation

public enum DiskParser {
    public static func isWholeDiskID(_ value: String) -> Bool {
        value.range(of: "\\Adisk[0-9]+\\z", options: .regularExpression) != nil
    }

    /// The input must come from `diskutil list -plist physical`.
    public static func physicalDisks(from data: Data) throws -> [PhysicalDisk] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = root["AllDisksAndPartitions"] as? [[String: Any]] else {
            throw DiskError("디스크 목록 형식 오류", "macOS에서 반환한 디스크 목록을 읽지 못했습니다.")
        }
        return disks.compactMap { item in
            guard let id = item["DeviceIdentifier"] as? String, isWholeDiskID(id) else { return nil }
            // OSInternal describes OS-managed storage, not whether hardware is internal.
            return PhysicalDisk(id: id, name: id, size: (item["Size"] as? NSNumber)?.int64Value ?? 0,
                                isInternal: nil, connection: "미확인", isSSD: nil)
        }
    }

    public static func enrich(_ disk: PhysicalDisk, from data: Data) throws -> PhysicalDisk {
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["DeviceIdentifier"] as? String == disk.id else {
            throw DiskError("디스크 정보 형식 오류", "선택한 디스크의 정보를 읽지 못했습니다.")
        }
        let name = info["MediaName"] as? String ?? disk.name
        let size = (info["TotalSize"] as? NSNumber)?.int64Value ?? (info["Size"] as? NSNumber)?.int64Value ?? disk.size
        let tree = info["DeviceTreePath"] as? String ?? ""
        return PhysicalDisk(id: disk.id, name: name, size: size, isInternal: info["Internal"] as? Bool,
                            connection: info["BusProtocol"] as? String ?? "미확인", isSSD: info["SolidState"] as? Bool,
                            identity: "\(disk.id):\(name):\(size):\(tree)")
    }
}

public enum SMARTParser {
    public static func parse(_ data: Data, exitCode: Int32 = 0, date: Date = Date()) throws -> SMARTSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiskError("SMART 응답 형식 오류", "smartctl의 JSON 응답을 읽지 못했습니다. smartmontools를 업데이트한 후 다시 시도하세요.",
                            details: String(data: data, encoding: .utf8) ?? "")
        }
        let tool = root.object("smartctl")
        let status = Int(exitCode) | (tool.integer("exit_status") ?? 0)
        let messages = (tool["messages"] as? [[String: Any]] ?? []).compactMap { $0["string"] as? String }
        let rawLines = tool["output"] as? [String]
        let json = String(data: data, encoding: .utf8) ?? ""
        let raw = rawLines?.joined(separator: "\n") ?? json
        if status & 0b11 != 0 { throw DiskError.smartFailure(messages.isEmpty ? raw : messages.joined(separator: "\n")) }
        let nvme = root.object("nvme_smart_health_information_log")
        let passed = root.object("smart_status")["passed"] as? Bool
        let temperature = root.object("temperature").integer("current") ?? nvme.integer("temperature")
        let attributes = root.object("ata_smart_attributes")["table"] as? [[String: Any]] ?? []
        let hasTelemetry = passed != nil || temperature != nil || !nvme.isEmpty || !attributes.isEmpty
        guard hasTelemetry else {
            throw DiskError.smartFailure(messages.isEmpty ? "장치가 사용 가능한 SMART 데이터를 반환하지 않았습니다.\n\(raw)" : messages.joined(separator: "\n"))
        }

        let warningTemp = root.object("temperature").integer("op_limit_max")
            ?? root.object("nvme_composite_temperature_threshold").integer("warning")
        let criticalTemp = root.object("temperature").integer("critical_limit_max")
            ?? root.object("nvme_composite_temperature_threshold").integer("critical")
        let percentageUsed = nvme.integer("percentage_used") ?? root.object("endurance_used").integer("current_percent")
        let spare = nvme.integer("available_spare") ?? root.object("spare_available").integer("current_percent")
        let spareThreshold = nvme.integer("available_spare_threshold") ?? root.object("spare_available").integer("threshold_percent")
        // NVMe data units contain 1,000 × 512 bytes, not sectors of an arbitrary device block size.
        let bytesRead = nvme.number("data_units_read").map { $0 * 512_000 }
        let bytesWritten = nvme.number("data_units_written").map { $0 * 512_000 }
        let hours = root.object("power_on_time").number("hours") ?? nvme.number("power_on_hours")
        let cycles = root.number("power_cycle_count") ?? nvme.number("power_cycles")
        let mediaErrors = nvme.number("media_errors")
        let criticalWarning = nvme.integer("critical_warning") ?? 0
        var warnings: [String] = []
        if passed == false || status & 8 != 0 { warnings.append("SMART 자체 평가에서 오류가 감지되었습니다. 중요한 데이터를 백업하세요.") }
        if criticalWarning != 0 { warnings.append(String(format: "NVMe 중요 경고: 0x%02X", criticalWarning)) }
        if status & 16 != 0 { warnings.append("현재 임계값에 도달한 SMART 속성이 있습니다.") }
        if let t = temperature, let limit = criticalTemp, t >= limit { warnings.append("현재 온도가 장치의 위험 온도에 도달했습니다.") }
        else if let t = temperature, let limit = warningTemp, t >= limit { warnings.append("현재 온도가 장치의 경고 온도에 도달했습니다.") }
        if let used = percentageUsed, used >= 100 { warnings.append("제조사가 추정한 정격 수명 사용률이 100% 이상입니다.") }
        if let available = spare, let threshold = spareThreshold, available < threshold { warnings.append("사용 가능한 예비 공간이 장치의 임계값보다 적습니다.") }
        if let errors = mediaErrors, errors > 0 { warnings.append("미디어 또는 데이터 무결성 오류 기록이 있습니다.") }
        if status & 4 != 0 { warnings.append("일부 SMART 항목을 읽지 못했습니다. 표시된 값은 부분 응답입니다.") }
        if status & 32 != 0 { warnings.append("과거 임계값에 도달한 SMART 속성 기록이 있습니다.") }
        if status & 64 != 0 { warnings.append("장치 오류 로그에 기록이 있습니다.") }
        if status & 128 != 0 { warnings.append("자가 진단 오류 기록이 있습니다.") }
        warnings.append(contentsOf: messages)
        let failing = passed == false || status & 24 != 0 || criticalWarning != 0
            || (temperature != nil && criticalTemp != nil && temperature! >= criticalTemp!)
        let health: DiskHealth = failing ? .failing : (!warnings.isEmpty ? .warning : (passed == true ? .healthy : .unknown))
        func count(_ key: String) -> String { DisplayFormat.count(nvme.number(key)) }
        func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }
        var metrics: [SMARTMetric] = [
            .init("used", "수명 사용률", percent(percentageUsed), "제조사 추정 소모율 · 디스크 사용 공간과 다름", "chart.pie"),
            .init("spare", "사용 가능한 예비 공간", percent(spare), spareThreshold.map { "장치 임계값 \($0)%" } ?? "장치에서 제공하는 예비 영역", "square.stack.3d.up"),
            .init("read", "누적 읽기", bytesRead.map(DisplayFormat.bytes) ?? "—", "디스크 수명 동안 읽은 데이터", "arrow.down.left"),
            .init("written", "누적 쓰기", bytesWritten.map(DisplayFormat.bytes) ?? "—", "디스크 수명 동안 기록한 데이터", "arrow.up.right"),
            .init("hours", "사용 시간", hours.map { "\(DisplayFormat.count($0))시간" } ?? "—", "전원이 켜져 있던 누적 시간", "clock"),
            .init("cycles", "전원 켠 횟수", DisplayFormat.count(cycles), "누적 전원 주기", "power"),
            .init("unsafe", "비정상 종료", count("unsafe_shutdowns"), "안전 종료 없이 전원이 끊긴 기록", "powerplug"),
            .init("errors", "미디어 오류", DisplayFormat.count(mediaErrors), "미디어 및 데이터 무결성 오류", "exclamationmark.shield"),
            .init("errorLog", "오류 로그 항목", count("num_err_log_entries"), "누적 오류 정보 로그 수", "list.bullet.rectangle"),
            .init("busy", "컨트롤러 사용 시간", nvme.number("controller_busy_time").map { "\(DisplayFormat.count($0))분" } ?? "—", "입출력 명령을 처리한 누적 시간", "cpu"),
            .init("warningTime", "경고 온도 유지 시간", nvme.number("warning_temp_time").map { "\(DisplayFormat.count($0))분" } ?? "—", "장치 경고 온도 이상으로 동작한 시간", "thermometer.medium"),
            .init("criticalTime", "위험 온도 유지 시간", nvme.number("critical_comp_time").map { "\(DisplayFormat.count($0))분" } ?? "—", "장치 위험 온도 이상으로 동작한 시간", "thermometer.high")
        ]
        // ATA raw values are vendor-specific; show them without guessing their units.
        for attribute in attributes {
            guard let id = attribute.integer("id") else { continue }
            let rawValue = attribute.object("raw")
            let value = rawValue["string"] as? String ?? DisplayFormat.count(rawValue.number("value"))
            let name = attribute["name"] as? String ?? "Attribute \(id)"
            metrics.append(.init("ata-\(id)", name, value,
                                 "ATA \(id) · 정규화 값 \(DisplayFormat.count(attribute.number("value"))) · 임계값 \(DisplayFormat.count(attribute.number("thresh")))", "list.number"))
        }
        return SMARTSnapshot(date: date, model: root["model_name"] as? String ?? root["product"] as? String ?? "알 수 없는 모델",
            serial: root["serial_number"] as? String ?? "—", firmware: root["firmware_version"] as? String ?? root["revision"] as? String ?? "—",
            protocolName: root.object("device")["protocol"] as? String ?? "미확인", temperature: temperature,
            warningTemperature: warningTemp, criticalTemperature: criticalTemp,
            warningTemperatureMinutes: nvme.number("warning_temp_time"), criticalTemperatureMinutes: nvme.number("critical_comp_time"),
            sensors: (nvme["temperature_sensors"] as? [NSNumber] ?? []).map(\.intValue), passed: passed,
            health: health, warnings: warnings, percentageUsed: percentageUsed, availableSpare: spare,
            bytesRead: bytesRead, bytesWritten: bytesWritten, powerOnHours: hours, metrics: metrics,
            rawText: raw, rawJSON: json, exitStatus: status)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func number(_ key: String) -> Double? {
        let result = (self[key + "_s"] as? String).flatMap(Double.init)
            ?? (self[key] as? NSNumber)?.doubleValue
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    func integer(_ key: String) -> Int? {
        guard let value = number(key), value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
}
