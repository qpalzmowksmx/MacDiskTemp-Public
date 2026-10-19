import Foundation
import UserNotifications
import AlertCore
import Combine

@MainActor public final class MacNotificationGateway: NSObject, ObservableObject, NotificationGateway, UNUserNotificationCenterDelegate {
    @Published public private(set) var acceptedCount = 0
    @Published public private(set) var foregroundCount = 0
    private let center: UNUserNotificationCenter
    private var canceled: Set<String> = []
    public override init() {
        center = .current()
        super.init()
        center.delegate = self
    }
    public func permission() async throws -> AlertPermission {
        let value = await center.notificationSettings()
        switch value.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized:
            return value.alertSetting == .enabled ? .allowed(sound: value.soundSetting == .enabled) : .limited
        default: return .limited
        }
    }
    public func requestPermission() async throws -> AlertPermission {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return try await permission()
    }
    public func add(_ notification: AlertNotification) async throws {
        guard !canceled.contains(notification.id) else { throw CancellationError() }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        if notification.sound { content.sound = .default }
        do { try await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)) }
        catch {
            let denied = (try? await permission())?.canSend == false
            throw AlertFailure(error.localizedDescription, retryable: !denied)
        }
        if canceled.contains(notification.id) { cancel([notification.id]) }
        acceptedCount += 1
    }
    public func cancel(_ ids: [String]) {
        canceled.formUnion(ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    public func pendingIDs() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    public func deliveredIDs() async -> [String] { await center.deliveredNotifications().map { $0.request.identifier } }
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        Task { @MainActor in
            if canceled.contains(id) { completionHandler([]) }
            else { foregroundCount += 1; completionHandler([.banner, .list, .sound]) }
        }
    }
}
