import Foundation

/// Finding the Appgate SDP client app, for the "Open Appgate" item.
public enum AppgateApp {
    public static let bundleIdentifier = "com.appgate.sdp"
    /// The names it ships under; older installs use "AppGate". On a
    /// case-insensitive volume (the default) either one matches.
    public static let names = ["Appgate SDP.app", "AppGate SDP.app"]

    /// By bundle id first, then by name in the application directories.
    public static func locate(
        bundleURL: (String) -> URL?,
        searchDirectories: [URL],
        exists: (URL) -> Bool
    ) -> URL? {
        if let url = bundleURL(bundleIdentifier) { return url }
        for directory in searchDirectories {
            for name in names {
                let url = directory.appendingPathComponent(name, isDirectory: true)
                if exists(url) { return url }
            }
        }
        return nil
    }
}
