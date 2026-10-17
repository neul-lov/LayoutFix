import AppKit
import SwiftUI

@main
struct LayoutFixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            StatusIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement hides the Dock icon in the bundle; this covers unbundled runs too.
        NSApp.setActivationPolicy(.accessory)
        if anotherInstanceIsRunning() {
            // Launched again (e.g. a second copy): show the running instance's Settings
            // instead of quitting silently.
            DistributedNotificationCenter.default().postNotificationName(
                Self.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSettingsRequested), name: Self.showSettingsNotification,
            object: nil, suspensionBehavior: .deliverImmediately)
        // `kill`, logout and launchd send SIGTERM; route it through the normal quit path so
        // hotkeys are unregistered and undo data is cleared.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
        model.start()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Settings: the only way in if
    /// the menu bar icon is hidden, e.g. behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showSettings() }
        return true
    }

    /// The settings window is optional UI; closing it must not quit the menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        model.shutdown()
    }

    static let showSettingsNotification = Notification.Name("dev.layoutfix.LayoutFix.showSettings")

    @objc private func showSettingsRequested(_ notification: Notification) {
        model.showSettings()
    }

    private func anotherInstanceIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != me }
    }
}

struct StatusIcon: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.needsAttention ? "exclamationmark.triangle" : "keyboard")
            .accessibilityLabel(model.statusHeadline)
    }
}
