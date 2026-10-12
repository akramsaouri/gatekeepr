import GatekeeprMenuBar
import SwiftUI

@main
struct MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                model: delegate.model,
                notifier: delegate.notifier,
                loginItem: delegate.loginItem,
                openAppgate: delegate.openAppgate
            )
        } label: {
            StatusLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The menu bar item: an icon and the time left, coloured in the warn window,
/// when expired and on errors.
struct StatusLabel: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Image(nsImage: StatusItemImage.make(model.state))
            .accessibilityLabel(model.state.accessibilityLabel)
    }
}
