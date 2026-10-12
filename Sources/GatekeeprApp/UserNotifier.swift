import AppKit
import GatekeeprMenuBar
import UserNotifications

/// Posts the warning and expiry notifications through Notification Center.
/// Clicking one opens Appgate SDP.
@MainActor
final class UserNotifier: NSObject, ObservableObject, SessionNotifier, UNUserNotificationCenterDelegate {
    /// The user turned notifications off for Gatekeepr; the menu offers a way back.
    @Published private(set) var isDenied = false
    var onOpen: (() -> Void)?

    /// Nil outside the app bundle, where UNUserNotificationCenter can't be used.
    private let center: UNUserNotificationCenter?

    init(enabled: Bool) {
        center = enabled ? .current() : nil
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error { Log.app.error("Notification permission request failed: \(error.localizedDescription)") }
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        center?.getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in
                guard let self, self.isDenied != denied else { return }
                self.isDenied = denied
            }
        }
    }

    func openSettings() {
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
            if let error { Log.app.error("Couldn't post a notification: \(error.localizedDescription)") }
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
