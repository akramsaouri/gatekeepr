import AppKit
import GatekeeprMenuBar
import UserNotifications

/// Posts the warning and expiry notifications through Notification Center.
/// Clicking one opens Appgate SDP.
@MainActor
final class UserNotifier: NSObject, ObservableObject, SessionNotifier, UNUserNotificationCenterDelegate {
    /// Notifications can't be shown: the user turned them off, or hasn't
    /// answered the permission prompt yet. The menu offers a way to fix it.
    @Published private(set) var needsPermission = false
    private var status: UNAuthorizationStatus = .authorized
    var onOpen: (() -> Void)?

    /// Nil outside the app bundle, where UNUserNotificationCenter can't be used.
    private let center: UNUserNotificationCenter?

    init(enabled: Bool) {
        center = enabled ? .current() : nil
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Log.app.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.app.notice("Notifications allowed: \(granted, privacy: .public)")
            }
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        center?.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard let self else { return }
                self.status = status
                let needed = status == .denied || status == .notDetermined
                if self.needsPermission != needed { self.needsPermission = needed }
            }
        }
    }

    /// Asks again if the prompt was never answered; otherwise only System
    /// Settings can turn notifications back on.
    func fixPermission() {
        if status == .notDetermined {
            requestAuthorization()
            return
        }
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(_ notification: SessionNotification) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Log.app.error("Couldn't post the \(notification.kind.rawValue, privacy: .public) notification: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.app.notice("Posted the \(notification.kind.rawValue, privacy: .public) notification")
            }
        }
    }

    func withdrawAll() {
        center?.removeAllDeliveredNotifications()
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show notifications even while the menu is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in self.onOpen?() }
        }
        completionHandler()
    }
}
