import Foundation
import AccessibilityText

/// Per-app rules applied before any text is read.
public struct AppPolicy: Sendable {
    /// Never read or modify text here, regardless of the focused field.
    public var excludedBundleIDs: Set<String>
    /// Apps where neither path works safely (terminals: ⌘V types into the shell instead of
    /// replacing, and ⌥⇧← sends escape sequences).
    public var unsupportedBundleIDs: Set<String>

    public init(excludedBundleIDs: Set<String>, unsupportedBundleIDs: Set<String>) {
        self.excludedBundleIDs = excludedBundleIDs
        self.unsupportedBundleIDs = unsupportedBundleIDs
    }

    public static let standard = AppPolicy(
        excludedBundleIDs: [
            "com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.keychainaccess", "com.apple.Passwords",
            "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
            "com.bitwarden.desktop", "com.lastpass.LastPass", "org.keepassxc.keepassxc",
            "in.sinew.Enpass-Desktop", "com.dashlane.dashlanephonefinal",
        ],
        unsupportedBundleIDs: [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
            "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty", "co.zeit.hyper",
        ]
    )

    public func isExcluded(_ app: AppIdentity) -> Bool {
        app.bundleIdentifier.map(excludedBundleIDs.contains) ?? false
    }

    public func isUnsupported(_ app: AppIdentity) -> Bool {
        app.bundleIdentifier.map(unsupportedBundleIDs.contains) ?? false
    }

    /// Electron editors (VS Code, Slack, …) expose a hidden IME textarea that holds only a
    /// slice of the document, so text read through Accessibility can be a partial line and
    /// word boundaries cannot be trusted. Those apps use the keyboard path instead.
    public func trustsAccessibilityText(_ app: AppIdentity) -> Bool {
        guard let url = app.bundleURL else { return true }
        let electron = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return !FileManager.default.fileExists(atPath: electron.path)
    }
}
