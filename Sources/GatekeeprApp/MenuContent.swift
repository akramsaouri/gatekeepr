import GatekeeprMenuBar
import SwiftUI

/// The menu under the menu bar item.
struct MenuContent: View {
    @ObservedObject var model: StatusModel
    @ObservedObject var notifier: UserNotifier
    @ObservedObject var loginItem: LoginItem
    let openAppgate: () -> Void

    var body: some View {
        Text(model.state.heading)
        ForEach(Array(model.state.details.enumerated()), id: \.offset) { _, line in
            Text(line)
        }
        if !model.state.history.isEmpty {
            Menu("Recent Sessions") {
                ForEach(Array(model.state.history.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
        }

        Divider()
        Button("Open Appgate", action: openAppgate)

        Divider()
        Picker("Warn Before Expiry", selection: $model.warnThreshold) {
            ForEach(model.warnThresholdChoices, id: \.self) { seconds in
                Text(Preferences.label(forWarnThreshold: seconds)).tag(seconds)
            }
        }
        .pickerStyle(.menu)
        if notifier.needsPermission {
            Button("Turn On Notifications…", action: notifier.fixPermission)
        }
        Toggle(loginItem.isAvailable ? "Launch at Login" : "Launch at Login (needs Gatekeepr.app)", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        ))
        .disabled(!loginItem.isAvailable)
        if loginItem.needsApproval {
            Button("Allow in Login Items Settings…", action: loginItem.openSettings)
        }

        Divider()
        Button("Quit Gatekeepr") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
