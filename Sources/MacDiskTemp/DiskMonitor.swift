import AppKit
import Combine
import DiskCore
import SwiftUI

@MainActor
final class DiskMonitor: ObservableObject {
    @Published private(set) var disks: [PhysicalDisk] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var snapshot: SMARTSnapshot?
    @Published private(set) var error: DiskError?
    @Published private(set) var isRefreshing = false
    @Published private(set) var temperatureSummary: TemperatureSummary?
    @Published private(set) var storageUsage: StorageUsage?
    @Published private(set) var storageMessage = "저장 공간을 조회하는 중입니다."
    @Published var showSettings = false
    @Published var showSetup = false
    let installer = DependencyInstaller()
    @Published var interval: Int {
        didSet {
            UserDefaults.standard.set(interval, forKey: "refreshInterval")
            temperatureHistory.pause()
            restartTimer()
        }
    }
    @Published var customPath: String {
        didSet { UserDefaults.standard.set(customPath, forKey: "smartctlPath") }
    }

    private let service = DiskService()
    private var timerTask: Task<Void, Never>?
    private var queuedRefresh = false
    private var queuedDiscovery = false
    private var selectionVersion = 0
    private var snapshotIdentity: String?
    private var temperatureHistory = TemperatureHistory()
    private var installationObserver: AnyCancellable?
    var selectedDisk: PhysicalDisk? { disks.first { $0.id == selectedID } }
    var resolvedPath: String? { DiskService.smartctlPath(customPath: customPath) }
    var isStale: Bool { error != nil }
    var menuTitle: String {
        guard !isStale, let snapshot else { return "—°C" }
        return snapshot.temperatureText
    }

    init() {
        let savedInterval = UserDefaults.standard.object(forKey: "refreshInterval") as? Int ?? 30
        interval = [0, 15, 30, 60, 300].contains(savedInterval) ? savedInterval : 30
        customPath = UserDefaults.standard.string(forKey: "smartctlPath") ?? ""
        selectedID = UserDefaults.standard.string(forKey: "selectedDisk")
        showSetup = resolvedPath == nil || installer.isRunning
        installationObserver = installer.$completed.filter { $0 }.sink { [weak self] _ in
            guard let self else { return }
            self.customPath = ""
            self.showSetup = false
            self.settingsChanged()
        }
        Task { await refresh(); restartTimer() }
    }

    func select(_ id: String) {
        guard selectedID != id else { return }
        selectedID = id
        UserDefaults.standard.set(id, forKey: "selectedDisk")
        invalidate()
        Task { await refresh(discover: false) }
    }

    func settingsChanged() {
        invalidate()
        Task { await refresh() }
    }

    private func invalidate() {
        selectionVersion += 1
        snapshot = nil
        snapshotIdentity = nil
        error = nil
        storageUsage = nil
        storageMessage = "저장 공간을 조회하는 중입니다."
        temperatureSummary = nil
        temperatureHistory.pause()
    }

    func refresh(discover: Bool = true) async {
        guard !installer.isRunning else { return }
        if isRefreshing {
            queuedRefresh = true
            queuedDiscovery = queuedDiscovery || discover
            return
        }
        isRefreshing = true
        var shouldDiscover = discover
        repeat {
            queuedRefresh = false
            queuedDiscovery = false
            await refreshOnce(discover: shouldDiscover)
            shouldDiscover = queuedDiscovery
        } while queuedRefresh
        isRefreshing = false
    }

    private func refreshOnce(discover: Bool) async {
        if discover {
            do {
                disks = try await service.disks()
                if !disks.contains(where: { $0.id == selectedID }) {
                    selectedID = disks.first(where: { $0.isInternal == false })?.id ?? disks.first?.id
                    UserDefaults.standard.set(selectedID, forKey: "selectedDisk")
                    invalidate()
                }
                if let disk = selectedDisk, let identity = snapshotIdentity, disk.identity != identity { invalidate() }
            } catch {
                self.error = error as? DiskError ?? DiskError("디스크 조회 실패", error.localizedDescription)
                temperatureHistory.pause()
                return
            }
        }
        guard let disk = selectedDisk else { snapshot = nil; error = nil; return }
        guard let path = resolvedPath else { error = .missingTool; temperatureHistory.pause(); return }
        let version = selectionVersion
        async let usage = readStorage(for: disk)
        do {
            let result = try await service.snapshot(for: disk, smartctlPath: path)
            let sampleUptime = ProcessInfo.processInfo.systemUptime
            let storage = await usage
            guard version == selectionVersion, disk.identity == selectedDisk?.identity else { return }
            // A reconnected device may reuse diskN. Never preserve the previous device's report.
            snapshot = result
            snapshotIdentity = disk.identity
            error = nil
            storageUsage = storage.0
            storageMessage = storage.1
            let key = TemperatureHistory.key(model: result.model, serial: result.serial, fallback: disk.identity)
            temperatureSummary = temperatureHistory.record(result.temperature, for: key, date: result.date,
                uptime: sampleUptime, maximumGap: interval > 0 ? Double(interval) + 25 : 0)
        } catch {
            guard version == selectionVersion, disk.id == selectedID else { return }
            self.error = error as? DiskError ?? DiskError("SMART 조회 실패", error.localizedDescription)
            temperatureHistory.pause()
        }
    }

    private func readStorage(for disk: PhysicalDisk) async -> (StorageUsage?, String) {
        do {
            let usage = try await service.storageUsage(for: disk)
            return (usage, usage == nil ? "사용량 정보가 없습니다. 볼륨이 마운트되어 있는지 확인하세요." : "")
        } catch { return (nil, error.localizedDescription) }
    }

    private func restartTimer() {
        timerTask?.cancel()
        guard interval > 0 else { timerTask = nil; return }
        let seconds = interval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func copyReport(json: Bool = false) {
        guard let snapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json ? snapshot.rawJSON : snapshot.rawText, forType: .string)
    }
}
