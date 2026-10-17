import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (macOS 13+), the supported replacement
/// for login items and helper apps.
enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user must allow it in System Settings › General › Login Items.
        case requiresApproval
        /// The system cannot find the app bundle (e.g. running an unbundled build).
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return Bundle.main.bundleIdentifier == nil ? .unavailable : .disabled
        @unknown default: return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
