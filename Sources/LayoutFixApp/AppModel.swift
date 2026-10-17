import AppKit
import Observation
import os
import AccessibilityText
import ClipboardBridge
import ConversionEngine
import HangulLayout
import HotKeys

enum SettingsTab: String, Hashable {
    case general, shortcuts, permissions
}

/// App state shared by the menu and the settings window.
@MainActor
@Observable
final class AppModel {
    // Persisted preferences
    var direction: ConversionDirection {
        didSet { preferences.direction = direction }
    }
    private(set) var hotKeys: [HotKeyAction: KeyCombo?]
    var allowClipboardFallback: Bool {
        didSet {
            preferences.allowClipboardFallback = allowClipboardFallback
            engine.settings.allowClipboardFallback = allowClipboardFallback
        }
    }
    var beepOnFailure: Bool {
        didSet { preferences.beepOnFailure = beepOnFailure }
    }

    // Live state
    private(set) var hotKeyResults: [HotKeyAction: HotKeyRegistrationResult] = [:]
    private(set) var accessibilityTrusted = false
    private(set) var lastStatus: String?
    private(set) var canUndo = false
    private(set) var launchAtLogin = LaunchAtLogin.state
    private(set) var launchAtLoginError: String?
    var settingsTab: SettingsTab = .general

    @ObservationIgnored private let preferences = Preferences()
    @ObservationIgnored private let engine: ConversionEngine
    @ObservationIgnored private let hotKeyManager = HotKeyManager()
    @ObservationIgnored private let settingsWindow = SettingsWindowController()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var promptedForPermissionThisSession = false
    @ObservationIgnored private var isPerforming = false
    /// The latest press that arrived while another action ran, and the app it was pressed in.
    @ObservationIgnored private var pendingAction: (action: HotKeyAction, pid: pid_t?)?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    @ObservationIgnored private var recordingCount = 0
    @ObservationIgnored private let permissionObserver = PermissionObserver()
    @ObservationIgnored private let focusProvider = AXFocusProvider()
    @ObservationIgnored private let log = Logger(subsystem: "dev.layoutfix.LayoutFix", category: "app")

    init() {
        direction = preferences.direction
        hotKeys = preferences.hotKeys
        allowClipboardFallback = preferences.allowClipboardFallback
        beepOnFailure = preferences.beepOnFailure

        var settings = EngineSettings()
        settings.allowClipboardFallback = preferences.allowClipboardFallback
        engine = ConversionEngine(focus: AXFocusProvider(), system: SystemState(),
                                  pasteboard: SystemPasteboard(), keys: CGKeystrokeSender(), settings: settings)
        engine.isEnglishWord = { EnglishDictionary.isWord($0) }
    }

    // MARK: Lifecycle

    func start() {
        hotKeyManager.onPress = { [weak self] name in
            guard let action = HotKeyAction(rawValue: name) else { return }
            Task { @MainActor in await self?.perform(action) }
        }
        registerHotKeys()
        refreshPermission()

        // Permission changes: an event-driven notification instead of polling, delivered even
        // while this accessory app is inactive (which is almost always).
        permissionObserver.start { [weak self] in
            // The notification can arrive before the new value is readable.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                self?.refreshPermission()
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission(); self?.refreshLaunchAtLogin() }
        })

        // First run without permission: explain it right away. `--settings` opens the window
        // on launch (`open -a LayoutFix --args --settings`).
        if !accessibilityTrusted {
            showSettings(tab: .permissions)
        } else if CommandLine.arguments.contains("--settings") {
            showSettings(tab: .general)
        }
        reportHotKeyProblemsIfAny()
    }

    /// Releases hotkeys and observers and drops any text held for undo.
    func shutdown() {
        hotKeyManager.shutdown()
        undoExpiry?.cancel()
        permissionObserver.stop()
        engine.clearTemporaryData()
        observers.forEach { NotificationCenter.default.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        log.notice("Shut down; hotkeys released and temporary data cleared")
    }

    // MARK: Actions

    /// Runs `action`, or queues it if one is already running. Only the latest queued press is
    /// kept, so a quick "convert, then undo" is not dropped as busy. Every queued action is
    /// fully re-validated by the engine when it runs.
    func perform(_ action: HotKeyAction) async {
        if isPerforming {
            pendingAction = (action, focusProvider.frontmostApp()?.pid)
            return
        }
        isPerforming = true
        await run(action)
        while let queued = pendingAction {
            pendingAction = nil
            // A queued press belongs to the app it was pressed in; never run it elsewhere.
            if queued.pid == focusProvider.frontmostApp()?.pid {
                await run(queued.action)
            } else {
                lastStatus = "Skipped a queued shortcut: the active app changed"
            }
        }
        isPerforming = false
    }

    private func run(_ action: HotKeyAction) async {
        refreshPermission()
        let outcome: EngineOutcome
        switch action {
        case .convert: outcome = await engine.convert(direction: direction)
        case .toKorean: outcome = await engine.convert(direction: .englishToKorean)
        case .toEnglish: outcome = await engine.convert(direction: .koreanToEnglish)
        case .undo: outcome = await engine.undo()
        }
        // Only the outcome category is logged, never text.
        log.info("\(action.rawValue, privacy: .public): \(outcome.message, privacy: .public)")
        lastStatus = outcome.message
        canUndo = engine.canUndo
        scheduleUndoExpiry()

        if !outcome.isSuccess, beepOnFailure, outcome != .refused(.busy) {
            NSSound.beep()
        }
        if outcome == .refused(.accessibilityPermissionDenied), !promptedForPermissionThisSession {
            promptedForPermissionThisSession = true
            showSettings(tab: .permissions)
        }
    }

    /// One-shot timer (not polling) that drops the undo text when its lifetime ends.
    private func scheduleUndoExpiry() {
        undoExpiry?.cancel()
        guard canUndo else { return }
        let lifetime = EngineSettings().undoLifetime
        undoExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(lifetime + 1))
            guard !Task.isCancelled, let self else { return }
            self.engine.discardExpiredUndo()
            self.canUndo = self.engine.canUndo
        }
    }

    /// Menu items run after the menu has closed and focus is back in the target app.
    func performFromMenu(_ action: HotKeyAction) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            await perform(action)
        }
    }

    // MARK: Hotkeys

    func setHotKey(_ combo: KeyCombo?, for action: HotKeyAction) {
        hotKeys[action] = .some(combo)
        preferences.hotKeys = hotKeys
        if recordingCount == 0 { registerHotKeys() }
    }

    func restoreDefaultHotKeys() {
        hotKeys = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, .some($0.defaultCombo)) })
        preferences.hotKeys = hotKeys
        if recordingCount == 0 { registerHotKeys() }
    }

    /// While a recorder listens, global hotkeys are released so the current shortcut can be
    /// typed into it instead of firing. They come back when no recorder is listening.
    func setRecording(_ recording: Bool) {
        recordingCount = max(0, recordingCount + (recording ? 1 : -1))
        if recording, recordingCount == 1 {
            hotKeyManager.unregisterAll()
        } else if !recording, recordingCount == 0 {
            registerHotKeys()
        }
    }

    func registerHotKeys() {
        let bindings = HotKeyAction.allCases.map { (name: $0.rawValue, combo: hotKeys[$0] ?? nil) }
        let results = hotKeyManager.register(bindings)
        hotKeyResults = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, results[$0.rawValue] ?? .disabled) })
        for (action, result) in hotKeyResults where result.isProblem {
            log.error("Hotkey \(action.rawValue, privacy: .public) not registered: \(result.message, privacy: .public)")
        }
    }

    var hotKeyProblems: [(HotKeyAction, HotKeyRegistrationResult)] {
        HotKeyAction.allCases.compactMap { action in
            hotKeyResults[action].flatMap { $0.isProblem ? (action, $0) : nil }
        }
    }

    func comboText(for action: HotKeyAction) -> String {
        guard let combo = hotKeys[action] ?? nil else { return "not set" }
        return combo.description
    }

    private func reportHotKeyProblemsIfAny() {
        let problems = hotKeyProblems
        guard !problems.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some LayoutFix shortcuts are unavailable"
        alert.informativeText = problems
            .map { "• \($0.0.title) (\(comboText(for: $0.0))): \($0.1.message)" }
            .joined(separator: "\n") + "\n\nChoose different shortcuts in Settings."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            showSettings(tab: .shortcuts)
        }
    }

    // MARK: Permissions

    func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            log.info("Accessibility permission: \(trusted ? "granted" : "not granted", privacy: .public)")
        }
    }

    func requestAccessibilityPrompt() {
        AccessibilityPermission.requestWithSystemPrompt()
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(AccessibilityPermission.settingsURL)
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        var failure: String?
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            failure = "Couldn't change the login item: \(error.localizedDescription)"
            log.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshLaunchAtLogin()
        launchAtLoginError = failure
    }

    func refreshLaunchAtLogin() {
        let state = LaunchAtLogin.state
        // An old error no longer applies once the state was fixed (e.g. approved in System Settings).
        if state != launchAtLogin || state == .enabled { launchAtLoginError = nil }
        launchAtLogin = state
    }

    // MARK: UI

    var statusHeadline: String {
        if !accessibilityTrusted { return "Accessibility permission needed" }
        let problems = hotKeyProblems.count
        if problems > 0 { return problems == 1 ? "1 shortcut unavailable" : "\(problems) shortcuts unavailable" }
        return "LayoutFix is running"
    }

    var needsAttention: Bool { !accessibilityTrusted || !hotKeyProblems.isEmpty }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        refreshLaunchAtLogin()
        settingsWindow.show(model: self)
    }
}

/// Observes Accessibility permission changes with `.deliverImmediately`, which the block-based
/// API cannot request; otherwise notifications wait until the (accessory) app is activated.
final class PermissionObserver: NSObject {
    private var handler: (() -> Void)?

    func start(_ handler: @escaping () -> Void) {
        self.handler = handler
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed), name: AccessibilityPermission.changedNotification,
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        handler = nil
    }

    @objc private func changed(_ notification: Notification) {
        handler?()
    }
}
