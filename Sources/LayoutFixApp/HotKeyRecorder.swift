import AppKit
import SwiftUI
import HotKeys

/// Click to record a shortcut. Esc cancels, Delete clears.
struct HotKeyRecorder: NSViewRepresentable {
    let combo: KeyCombo?
    let onChange: (KeyCombo?) -> Void
    let onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onChange = onChange
        button.onRecordingChange = onRecordingChange
        button.combo = combo
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onChange = onChange
        button.onRecordingChange = onRecordingChange
        if !button.isRecording { button.combo = combo }
    }
}

final class RecorderButton: NSButton {
    var combo: KeyCombo? { didSet { updateTitle() } }
    var onChange: ((KeyCombo?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// Only one recorder listens at a time; starting another cancels this one.
    private static weak var active: RecorderButton?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        if let other = Self.active, other !== self { other.stopRecording() }
        Self.active = self
        isRecording = true
        onRecordingChange?(true)
        title = "Type shortcut…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        // Global hotkeys are suspended while recording. Whatever ends the recording session
        // (closing the window, switching apps) must also end recording, or they stay off.
        let center = NotificationCenter.default
        let stop: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        if let window {
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: stop))
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: stop))
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: stop))
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if Self.active === self { Self.active = nil }
        isRecording = false
        updateTitle()
        onRecordingChange?(false)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .flagsChanged {
            title = flags.isEmpty ? "Type shortcut…" : Self.symbols(for: flags) + "…"
            return nil
        }
        switch Int(event.keyCode) {
        case 53 where flags.isEmpty: // Esc
            stopRecording()
        case 51 where flags.isEmpty, 117 where flags.isEmpty: // Delete / Forward Delete
            combo = nil
            onChange?(nil)
            stopRecording()
        default:
            guard !KeyCombo.isModifierKey(event.keyCode) else { return nil }
            let newCombo = KeyCombo(keyCode: event.keyCode, modifierFlags: flags)
            if newCombo.validationProblem != nil {
                NSSound.beep()
                title = Self.symbols(for: flags) + "… (add ⌃, or ⌘⌥)"
                return nil
            }
            combo = newCombo
            onChange?(newCombo)
            stopRecording()
        }
        return nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateTitle() {
        title = combo?.description ?? "Click to set"
    }

    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
}
