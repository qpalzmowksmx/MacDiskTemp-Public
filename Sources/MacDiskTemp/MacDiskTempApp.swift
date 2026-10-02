import SwiftUI
import AppKit

@main
struct MacDiskTempApp: App {
    @StateObject private var monitor = DiskMonitor()

    var body: some Scene {
        Window("MacDiskTemp", id: "main") {
            ContentView(monitor: monitor)
                .frame(minWidth: 940, minHeight: 670)
                .tint(.teal)
        }
        .defaultSize(width: 1120, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("디스크 새로고침") { Task { await monitor.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("설정…") { monitor.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Label(monitor.menuTitle, systemImage: "internaldrive")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var monitor: DiskMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(monitor.selectedDisk?.name ?? "MacDiskTemp")
        if let snapshot = monitor.snapshot, !monitor.isStale {
            Text("\(snapshot.temperatureText) · \(snapshot.health.title)")
            Text("측정 \(snapshot.date.formatted(date: .omitted, time: .standard))")
        } else if monitor.isStale {
            Text("측정값을 확인할 수 없습니다")
        } else {
            Text(monitor.isRefreshing ? "디스크를 확인하는 중…" : "디스크를 선택하세요")
        }
        Divider()
        ForEach(monitor.disks) { disk in
            Button {
                monitor.select(disk.id)
            } label: {
                if disk.id == monitor.selectedID { Label(disk.name, systemImage: "checkmark") }
                else { Text(disk.name) }
            }
        }
        Divider()
        Button("대시보드 열기") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("새로고침") { Task { await monitor.refresh() } }
            .disabled(monitor.isRefreshing)
        Divider()
        Button("MacDiskTemp 종료") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
