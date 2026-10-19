import SwiftUI
import AlertCore
import MacAlertSupport

@main struct AlertHarnessApp: App {
    @StateObject private var alerts: AlertCoordinator
    @StateObject private var gateway: MacNotificationGateway
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDiskTemp-NotificationTest", isDirectory: true)
        let gateway = MacNotificationGateway()
        _gateway = StateObject(wrappedValue: gateway)
        _alerts = StateObject(wrappedValue: AlertCoordinator(gateway: gateway,
            store: FileAlertStore(url: directory.appendingPathComponent("alerts.json")), clock: ContinuousAlertClock()))
    }
    var body: some Scene { WindowGroup { HarnessView(alerts: alerts, gateway: gateway) } }
}

struct HarnessView: View {
    @ObservedObject var alerts: AlertCoordinator
    @ObservedObject var gateway: MacNotificationGateway
    @State private var session: UUID?
    @State private var sequence: UInt64 = 0
    @State private var deliveredCount = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MacDiskTemp 알림 시험 앱").font(.title2.bold())
            Text("별도 권한·저장소를 사용하며 실제 디스크를 읽지 않습니다.")
            Text(alerts.permission?.title ?? "권한 확인 중")
            Text(alerts.storageError ?? alerts.message).textSelection(.enabled)
            HStack {
                Button("알림 켜기 · 70°C") {
                    var draft = AlertDraft(alerts.settings); draft.enabled = true; draft.threshold = "70"
                    do { try alerts.save(draft) } catch { return }
                    if let session { Task { await alerts.requestSavedPermission(session: session) } }
                }
                Button("알림 끄기") {
                    var draft = AlertDraft(alerts.settings); draft.enabled = false; _ = try? alerts.save(draft)
                }
                Button("시험 알림") { if let session { alerts.sendTest(session: session) } }.disabled(alerts.testBusy)
            }
            HStack {
                Button("고온 75°C 측정") { measure(75) }
                Button("냉각 68°C 측정") { measure(68) }
                Button("측정 실패") { alerts.measurementFailed() }
                Button("권한 새로고침") { Task { await alerts.refreshPermission() } }
            }
            Text("알림 \(alerts.settings.enabled ? "켜짐" : "꺼짐") · 측정 이벤트 \(sequence)회")
            Text("OS 접수 \(gateway.acceptedCount)건 · 전경 표시 요청 \(gateway.foregroundCount)건 · 알림 센터 \(deliveredCount)건")
            Button("OS 알림 센터 기록 확인") { Task { deliveredCount = await gateway.deliveredIDs().count } }
        }.padding(28).frame(width: 650)
            .task { await alerts.start(); session = alerts.openEditor() }
    }
    private func measure(_ value: Int) {
        sequence += 1
        alerts.receive(.init(device: "fixture-device", name: "시험용 SSD", context: alerts.context,
            rule: alerts.settings.rule, sequence: sequence, started: alerts.now, completed: alerts.now,
            temperature: value), maximumGap: 325)
    }
}
