import AppKit
import GatekeeprMenuBar
import os

enum Log {
    static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "gatekeepr", category: "app")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: StatusModel
    let notifier: UserNotifier
    let loginItem: LoginItem

    override init() {
        // Notifications and launch at login need the app bundle. Run bare (from
        // `swift run GatekeeprApp`), the menu still works without them.
        let bundled = Bundle.main.bundleIdentifier != nil
        if !bundled {
            Log.app.notice("Not running from Gatekeepr.app: notifications and launch at login are off")
        }
        notifier = UserNotifier(enabled: bundled)
        loginItem = LoginItem(enabled: bundled)
        let preferences = Preferences()
        model = StatusModel(logDirectory: preferences.logDirectory, preferences: preferences, notifier: notifier)
        super.init()
        notifier.onOpen = { [weak self] in self?.openAppgate() }
        model.onEvaluate = { [weak self] in
            self?.notifier.refresh()
            self?.loginItem.refresh()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement; this covers running outside the bundle.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.requestAuthorization()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func openAppgate() {
        let workspace = NSWorkspace.shared
        let directories = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        guard let url = AppgateApp.locate(
            bundleURL: workspace.urlForApplication(withBundleIdentifier:),
            searchDirectories: directories,
            exists: { FileManager.default.fileExists(atPath: $0.path) }
        ) else {
            Self.alert("Couldn't find Appgate SDP",
                       "Looked for the app with bundle id \(AppgateApp.bundleIdentifier), and for "
                       + "\(AppgateApp.names[0]) in \(directories.map(\.path).joined(separator: " and ")).")
            return
        }
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in
                Self.alert("Couldn't open Appgate SDP", error.localizedDescription)
            }
        }
    }

    static func alert(_ message: String, _ information: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
