import AppKit
import ServiceManagement

/// Launch at login, through SMAppService (the app registers itself; no helper).
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    /// False outside the app bundle, where SMAppService can't register anything.
    let isAvailable: Bool

    var isEnabled: Bool { status == .enabled }
    /// Registered, but the user has to allow it in System Settings › Login Items.
    var needsApproval: Bool { status == .requiresApproval }

    init(enabled: Bool) {
        isAvailable = enabled
        refresh()
    }

    func refresh() {
        guard isAvailable else { return }
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppDelegate.alert(
                enabled ? "Couldn't turn on Launch at Login" : "Couldn't turn off Launch at Login",
                "\(error.localizedDescription)\n\nIf Gatekeepr.app isn't in Applications yet, move it there and try again."
            )
        }
        refresh()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
