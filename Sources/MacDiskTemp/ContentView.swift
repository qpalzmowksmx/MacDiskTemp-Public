import SwiftUI
import AppKit
import DiskCore
import AlertCore

private enum DetailTab: String, CaseIterable { case smart = "SMART 상세", device = "장치 정보", raw = "SMART 원문" }

struct ContentView: View {
    @ObservedObject var monitor: DiskMonitor
    @State private var tab: DetailTab = .smart
    @State private var showJSON = false
    @State private var copied = false
    @State private var showMore = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 225, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                if let disk = monitor.selectedDisk {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            diskHeading(disk)
                            if let error = monitor.error { errorBanner(error) }
                            if let snapshot = monitor.snapshot {
                                overview(disk, snapshot)
                            } else if monitor.isRefreshing && monitor.error == nil {
                                ProgressView("SMART 정보를 읽는 중…").frame(maxWidth: .infinity, minHeight: 330)
                            } else if monitor.error == nil {
                                emptyState("측정을 시작하세요", "새로고침을 누르면 디스크 상태를 확인합니다.", "thermometer.medium")
                            }
                        }
                        .padding(28)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                } else if let error = monitor.error {
                    ScrollView { errorBanner(error).padding(28) }
                } else if monitor.isRefreshing {
                    ProgressView("연결된 디스크를 찾는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState("물리 디스크가 없습니다", "디스크를 연결한 후 새로고침하세요.", "externaldrive.badge.plus")
                }
                Divider()
                footer
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $monitor.showSettings) { SettingsView(monitor: monitor) }
        .sheet(isPresented: $monitor.showSetup) { SetupView(installer: monitor.installer) }
        .onChange(of: monitor.selectedID) { _ in showMore = false; tab = .smart }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill").font(.title2).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacDiskTemp").font(.headline)
                    Text("디스크 상태 모니터").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            List(selection: Binding(get: { monitor.selectedID }, set: { if let id = $0 { monitor.select(id) } })) {
                Section("연결된 디스크 · \(monitor.disks.count)") {
                    ForEach(monitor.disks) { disk in
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: disk.isInternal == true ? "internaldrive" : "externaldrive")
                                .font(.title2).foregroundStyle(disk.id == monitor.selectedID ? .primary : .secondary)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(disk.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                Text("\(disk.location) · \(disk.capacity)").font(.caption).foregroundStyle(.secondary)
                                Text(disk.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8).tag(disk.id)
                    }
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 10) {
                Label("물리 디스크만 표시", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Text("APFS 가상 볼륨과 디스크 이미지는 목록에서 제외됩니다.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { monitor.showSettings = true } label: { Label("설정", systemImage: "gearshape") }
                    .buttonStyle(.plain).padding(.top, 8)
            }.padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("디스크 대시보드").font(.headline)
            Spacer()
            if monitor.isRefreshing { ProgressView().controlSize(.small) }
            Picker("자동 갱신", selection: $monitor.interval) {
                Text("자동 갱신 끔").tag(0)
                Text("15초마다").tag(15)
                Text("30초마다").tag(30)
                Text("1분마다").tag(60)
                Text("5분마다").tag(300)
            }.labelsHidden().frame(width: 130).help("선택한 디스크의 자동 갱신 주기")
            Button { Task { await monitor.refresh() } } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                .disabled(monitor.isRefreshing).help("디스크 목록과 SMART 정보를 새로고침 (⌘R)")
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func diskHeading(_ disk: PhysicalDisk) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.teal.opacity(0.10)).frame(width: 62, height: 62)
                Image(systemName: disk.isInternal == true ? "internaldrive.fill" : "externaldrive.fill")
                    .font(.system(size: 30)).foregroundStyle(.teal)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(disk.name).font(.system(size: 23, weight: .semibold)).textSelection(.enabled)
                HStack(spacing: 8) {
                    badge(disk.location)
                    badge(disk.capacity)
                    badge(disk.connection)
                    Text(disk.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let snapshot = monitor.snapshot {
                Label(snapshot.health.title, systemImage: healthSymbol(snapshot.health))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(healthColor(snapshot.health))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(healthColor(snapshot.health).opacity(0.08), in: Capsule())
                    .help(snapshot.healthExplanation)
            }
        }
    }

    private func overview(_ disk: PhysicalDisk, _ snapshot: SMARTSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if monitor.isStale {
                Label("이전 측정값 · 마지막 성공 \(snapshot.date.formatted(date: .abbreviated, time: .standard))", systemImage: "clock.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
            }
            if snapshot.health == .failing {
                Label(snapshot.healthExplanation, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                summaryCard("현재 온도", symbol: "thermometer.medium") {
                    temperatureValue(snapshot.temperature.map(String.init) ?? "—", color: temperatureColor(snapshot))
                    Spacer(minLength: 0)
                    Text("마지막 측정 \(snapshot.date.formatted(date: .omitted, time: .standard))").summaryNote()
                }
                summaryCard("최고 온도", symbol: "thermometer.high", information: true) {
                    temperatureValue(monitor.temperatureSummary.map { String($0.maximum) } ?? "—", color: .orange)
                    Spacer(minLength: 0)
                    Text("누적 측정 중 최고값").summaryNote()
                }
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .help(maximumTemperatureHelp(snapshot))
                .accessibilityElement(children: .combine)
                .accessibilityHint(maximumTemperatureHelp(snapshot))
                summaryCard("평균 온도", symbol: "waveform.path") {
                    temperatureValue(monitor.temperatureSummary.map {
                        $0.average.formatted(.number.precision(.fractionLength(1)))
                    } ?? "—", color: .teal)
                    Spacer(minLength: 0)
                    Text("성공한 온도 측정값의 평균").summaryNote()
                }
                summaryCard("남은 수명", symbol: "heart") {
                    let remaining = snapshot.percentageUsed.map { max(0, 100 - $0) }
                    summaryValue(remaining.map { "\($0)%" } ?? "—")
                    Spacer(minLength: 0)
                    if let remaining {
                        ProgressView(value: Double(remaining), total: 100).tint(remaining <= 10 ? .orange : .teal)
                    }
                    Text(snapshot.percentageUsed.map { "수명 사용률 \($0)% · 제조사 추정" } ?? "장치가 수명 정보를 제공하지 않습니다.").summaryNote()
                }
                summaryCard("저장 공간", symbol: "chart.pie") {
                    if let usage = monitor.storageUsage {
                        summaryValue("\(usage.usedPercentage.formatted(.number.precision(.fractionLength(1))))%")
                        Spacer(minLength: 0)
                        ProgressView(value: usage.usedPercentage, total: 100).tint(.teal)
                        Text("\(DisplayFormat.bytes(usage.usedBytes)) / \(DisplayFormat.bytes(usage.totalBytes)) 사용").summaryNote()
                    } else {
                        summaryValue("—")
                        Spacer(minLength: 0)
                        Text(monitor.storageMessage).summaryNote()
                    }
                }
                .help(storageHelp)
                summaryCard("누적 읽기 · 쓰기", symbol: "arrow.up.arrow.down") {
                    transferValue("읽기", bytes: snapshot.bytesRead, symbol: "arrow.down.left")
                    transferValue("쓰기", bytes: snapshot.bytesWritten, symbol: "arrow.up.right")
                    Spacer(minLength: 0)
                    Text("디스크 전체 사용 기간 기준").summaryNote()
                }
            }
            historyFooter
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showMore.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(showMore ? "접기" : "더보기")
                    Image(systemName: showMore ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                }.frame(maxWidth: .infinity).padding(.vertical, 9)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(showMore ? "SMART 상세 접기" : "SMART 데이터 더보기")
            if showMore {
                Divider()
                Picker("상세 보기", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 380)
                switch tab {
                case .smart: smartDetails(snapshot)
                case .device: deviceInfo(disk, snapshot)
                case .raw: rawOutput(snapshot)
                }
            }
        }
    }

    private func summaryCard<Content: View>(_ title: String, symbol: String, information: Bool = false,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                if information { Image(systemName: "info.circle").font(.caption) }
            }.foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 145, alignment: .topLeading)
        .padding(18).cardStyle()
    }

    private func temperatureValue(_ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 43, weight: .light, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.65).lineLimit(1).textSelection(.enabled)
            Text("°C").font(.system(size: 19, weight: .light)).foregroundStyle(.secondary)
        }.foregroundStyle(color)
    }

    private func summaryValue(_ value: String) -> some View {
        Text(value).font(.system(size: 33, weight: .medium, design: .rounded)).monospacedDigit()
            .minimumScaleFactor(0.6).lineLimit(1).textSelection(.enabled)
    }

    private func transferValue(_ title: String, bytes: Double?, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(bytes.map(DisplayFormat.bytes) ?? "—").font(.system(size: 21, weight: .medium, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55).textSelection(.enabled)
        }
    }

    private var historyFooter: some View {
        HStack(spacing: 10) {
            if let summary = monitor.temperatureSummary {
                Label("누적 측정 \(durationText(summary.measuredDuration))", systemImage: "clock")
                Text("· \(summary.sampleCount.formatted())회")
                Spacer()
                Text("이번 앱 실행 기준")
            } else {
                Text("온도를 측정하면 최고·평균 온도가 기록됩니다.")
                Spacer()
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
            .help(historyHelp)
    }

    private var historyHelp: String {
        guard let summary = monitor.temperatureSummary else { return "최고·평균 온도는 앱이 수집한 측정값을 기준으로 계산합니다." }
        return "첫 측정: \(summary.firstDate.formatted(date: .abbreviated, time: .standard))\n마지막 측정: \(summary.lastDate.formatted(date: .abbreviated, time: .standard))\n평균은 성공한 측정값의 산술 평균입니다. 누적 측정 시간에는 자동 갱신으로 연속 측정한 구간만 포함되며, 연결 해제·측정 공백은 제외됩니다.\n최고·평균 온도는 앱을 완전히 종료하면 초기화됩니다. 창만 닫으면 계속 누적됩니다."
    }

    private func maximumTemperatureHelp(_ snapshot: SMARTSnapshot) -> String {
        let warningTime = snapshot.warningTemperatureMinutes.map { "\(DisplayFormat.count($0))분" } ?? "미제공"
        let criticalTime = snapshot.criticalTemperatureMinutes.map { "\(DisplayFormat.count($0))분" } ?? "미제공"
        let warningLimit = snapshot.warningTemperature.map { "\($0)°C" } ?? "미제공"
        let criticalLimit = snapshot.criticalTemperature.map { "\($0)°C" } ?? "미제공"
        let peakDate = monitor.temperatureSummary.map { "최고 온도 측정: \($0.maximumDate.formatted(date: .abbreviated, time: .standard))\n\n" } ?? ""
        return peakDate + "SMART 온도 기록 · 디스크 전체 사용 기간\n경고 온도 유지 시간: \(warningTime)\n위험 온도 유지 시간: \(criticalTime)\n경고 기준: \(warningLimit) · 위험 기준: \(criticalLimit)"
    }

    private var storageHelp: String {
        guard let usage = monitor.storageUsage else { return monitor.storageMessage }
        return "\(usage.scope)\n사용: \(DisplayFormat.bytes(usage.usedBytes))\n남음: \(DisplayFormat.bytes(usage.freeBytes))\n전체: \(DisplayFormat.bytes(usage.totalBytes))\nAPFS 공유 공간은 컨테이너별로 한 번만 계산하며 시스템·스냅샷 공간을 포함합니다. EFI 및 미할당 공간은 제외됩니다."
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        if seconds >= 86400 { return "\(seconds / 86400)일 \((seconds % 86400) / 3600)시간" }
        if seconds >= 3600 { return "\(seconds / 3600)시간 \((seconds % 3600) / 60)분" }
        if seconds >= 60 { return "\(seconds / 60)분 \(seconds % 60)초" }
        return "\(seconds)초"
    }

    private func smartDetails(_ snapshot: SMARTSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Label("디스크 건강 상태 · \(snapshot.health.title)", systemImage: healthSymbol(snapshot.health))
                    .font(.headline).foregroundStyle(healthColor(snapshot.health))
                Text(snapshot.healthExplanation).font(.callout)
                Text(snapshot.passed.map { $0 ? "SMART 자체 평가: PASSED" : "SMART 자체 평가: FAILED" } ?? "SMART 자체 평가: 미제공")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(snapshot.warnings.dropFirst().enumerated()), id: \.offset) { _, warning in
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                }
                if !snapshot.sensors.isEmpty {
                    Divider()
                    Text(snapshot.sensors.enumerated().map { "센서 \($0.offset + 1)  \($0.element)°C" }.joined(separator: "    ·    "))
                        .font(.caption).monospacedDigit()
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20).cardStyle()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                ForEach(snapshot.metrics.filter { !["used", "read", "written", "warningTime", "criticalTime"].contains($0.id) }) { metric in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(metric.title, systemImage: metric.symbol).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(metric.value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
                        Text(metric.note).summaryNote().frame(minHeight: 28, alignment: .top)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18).cardStyle()
                }
            }
        }
    }

    private func deviceInfo(_ disk: PhysicalDisk, _ snapshot: SMARTSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("모델", snapshot.model)
            infoRow("일련번호", snapshot.serial)
            infoRow("펌웨어", snapshot.firmware)
            infoRow("프로토콜", snapshot.protocolName)
            infoRow("연결 방식", disk.connection)
            infoRow("디스크 종류", disk.isSSD.map { $0 ? "SSD" : "HDD / 기타" } ?? "미확인")
            infoRow("장치 경로", disk.path)
            infoRow("물리 용량", disk.capacity)
            infoRow("마지막 측정", snapshot.date.formatted(date: .abbreviated, time: .standard))
            infoRow("smartctl", monitor.resolvedPath ?? "찾을 수 없음")
            infoRow("SMART 종료 상태", String(snapshot.exitStatus))
        }.padding(20).cardStyle()
    }

    private func rawOutput(_ snapshot: SMARTSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("출력 형식", selection: $showJSON) {
                    Text("텍스트 원문").tag(false)
                    Text("JSON").tag(true)
                }.pickerStyle(.segmented).frame(width: 220)
                Spacer()
                Button {
                    monitor.copyReport(json: showJSON)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: { Label(copied ? "복사됨" : "원문 복사", systemImage: copied ? "checkmark" : "doc.on.doc") }
            }
            ScrollView(.horizontal) {
                Text(showJSON ? snapshot.rawJSON : snapshot.rawText)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.cardStyle()
        }
    }

    private func errorBanner(_ error: DiskError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.title, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            Text(error.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !error.details.isEmpty {
                DisclosureGroup("상세 내용") {
                    Text(error.details).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.caption)
            }
            if monitor.resolvedPath == nil {
                HStack {
                    Button("자동 설치…") { monitor.showSetup = true }
                    Button("smartctl 경로 설정") { monitor.showSettings = true }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(monitor.isStale ? .orange : (monitor.snapshot == nil ? .gray : .teal)).frame(width: 6, height: 6)
            if let snapshot = monitor.snapshot {
                Text("\(monitor.isStale ? "이전 측정" : "마지막 갱신") \(snapshot.date.formatted(date: .omitted, time: .standard))")
            } else { Text(monitor.isRefreshing ? "조회 중…" : "측정 대기") }
            Spacer()
            Text(monitor.interval == 0 ? "수동 갱신" : "선택한 디스크를 \(monitor.interval)초마다 갱신")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
    }

    private func emptyState(_ title: String, _ message: String, _ symbol: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 45)).foregroundStyle(.secondary)
            Text(title).font(.title2)
            Text(message).foregroundStyle(.secondary)
            Button("새로고침") { Task { await monitor.refresh() } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(50)
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 4).background(.primary.opacity(0.045), in: Capsule())
    }
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 125, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12)).padding(.vertical, 13)
    }
    private func temperatureColor(_ snapshot: SMARTSnapshot) -> Color {
        guard let temp = snapshot.temperature else { return .secondary }
        if let threshold = snapshot.criticalTemperature, temp >= threshold { return .red }
        if let threshold = snapshot.warningTemperature, temp >= threshold { return .orange }
        return .teal
    }
    private func healthColor(_ health: DiskHealth) -> Color {
        switch health { case .healthy: return .teal; case .warning: return .orange; case .failing: return .red; case .unknown: return .secondary }
    }
    private func healthSymbol(_ health: DiskHealth) -> String {
        switch health { case .healthy: return "checkmark.shield.fill"; case .warning: return "exclamationmark.shield.fill"; case .failing: return "xmark.shield.fill"; case .unknown: return "questionmark.circle" }
    }
}

private extension View {
    func summaryNote() -> some View {
        font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
    func cardStyle() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.055), lineWidth: 1))
    }
}

private struct SettingsView: View {
    @ObservedObject var monitor: DiskMonitor
    @ObservedObject var alerts: AlertCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AlertDraft(AlertSettings())
    @State private var session: UUID?
    @State private var inputError: String?
    init(monitor: DiskMonitor) {
        self.monitor = monitor
        self.alerts = monitor.alerts
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("설정").font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("smartctl 위치").font(.headline)
                Text("비워 두면 Homebrew의 기본 설치 경로를 자동으로 찾습니다.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("자동으로 찾기", text: $draft.smartctlPath).textFieldStyle(.roundedBorder)
                    Button("파일 선택…") { selectExecutable() }
                }
                Text("현재 위치: \(monitor.resolvedPath ?? "찾을 수 없음")")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Toggle("온도 알림 켜기", isOn: $draft.enabled)
                HStack {
                    Text("알림 기준 온도")
                    TextField("70", text: $draft.threshold).textFieldStyle(.roundedBorder)
                        .frame(width: 65).disabled(!draft.enabled)
                    Text("°C 초과 · 연속 2회")
                }
                Text(alerts.permission?.title ?? "알림 권한 확인 중…")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = inputError ?? alerts.storageError {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if !alerts.message.isEmpty {
                    Text(alerts.message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if monitor.interval == 0 {
                    Text("자동 갱신이 꺼져 있어 수동 측정 때만 온도를 확인합니다.").font(.caption).foregroundStyle(.orange)
                }
                if alerts.identityLimited {
                    Text("이 장치는 고유 식별 정보가 없어 재연결·재실행 후 중복 알림 방지가 제한됩니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button(alerts.testBusy ? "시험 알림 처리 중…" : "시험 알림") {
                    if let session { alerts.sendTest(session: session) }
                }.disabled(alerts.testBusy || !alerts.ready)
                Text("시험 알림은 저장하지 않아도 전송됩니다. 실제 온도 및 자동 알림 설정과 관계없습니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("앱은 Dock에 표시되지 않습니다. 창을 닫아도 메뉴 막대에서 온도를 확인하거나 ‘대시보드 열기’로 창을 다시 열 수 있습니다. 완전히 종료하려면 ‘MacDiskTemp 종료’를 선택하세요.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("자동 갱신 시 디스크가 절전 상태에서 깨어날 수 있습니다. 필요하면 갱신을 끄거나 간격을 늘리세요.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장") {
                    do {
                        try monitor.saveSettings(draft)
                        draft = AlertDraft(alerts.settings)
                        inputError = nil
                        if let session { Task { await alerts.requestSavedPermission(session: session) } }
                    } catch { inputError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 530)
            .onAppear { draft = AlertDraft(alerts.settings); session = alerts.openEditor() }
            .onDisappear { if let session { alerts.closeEditor(session) } }
    }
    private func selectExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "설치된 smartctl 실행 파일을 선택하세요."
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { draft.smartctlPath = url.path }
    }
}
