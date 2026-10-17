import Carbon.HIToolbox
import CoreGraphics

/// Synthetic keystrokes used by the clipboard fallback path.
@MainActor
public protocol KeystrokeSending {
    /// True when no modifier keys are physically held. Synthetic shortcuts sent while the
    /// user still holds the hotkey modifiers would combine with them (⌃⌥⌘C instead of ⌘C).
    func modifiersReleased() -> Bool
    func copy()          // ⌘C
    func paste()         // ⌘V
    func selectWordBackward() // ⌥⇧←
    func extendSelectionBackward(characters: Int) // ⇧← × n
    func collapseSelectionToEnd() // →
}

@MainActor
public struct CGKeystrokeSender: KeystrokeSending {
    public init() {}

    public func modifiersReleased() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    public func copy() { tap(CGKeyCode(kVK_ANSI_C), [.maskCommand]) }
    public func paste() { tap(CGKeyCode(kVK_ANSI_V), [.maskCommand]) }

    public func selectWordBackward() {
        tap(CGKeyCode(kVK_LeftArrow), [.maskAlternate, .maskShift, .maskNumericPad, .maskSecondaryFn])
    }

    public func extendSelectionBackward(characters: Int) {
        for _ in 0..<max(0, characters) {
            tap(CGKeyCode(kVK_LeftArrow), [.maskShift, .maskNumericPad, .maskSecondaryFn])
        }
    }

    public func collapseSelectionToEnd() {
        tap(CGKeyCode(kVK_RightArrow), [.maskNumericPad, .maskSecondaryFn])
    }

    private static let modifierKeys: [(flag: CGEventFlags, key: CGKeyCode)] = [
        (.maskControl, CGKeyCode(kVK_Control)), (.maskAlternate, CGKeyCode(kVK_Option)),
        (.maskShift, CGKeyCode(kVK_Shift)), (.maskCommand, CGKeyCode(kVK_Command)),
    ]

    /// Presses a shortcut the way a person does: modifier keys down, the key, modifier keys up.
    /// Posting only the key with modifier flags would leave the system believing ⌘ (etc.) is
    /// still held until the next real key press, turning the user's next click into ⌘-click.
    private func tap(_ key: CGKeyCode, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        let modifiers = Self.modifierKeys.filter { flags.contains($0.flag) }
        let extraFlags = flags.subtracting([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        var held: CGEventFlags = []
        func post(_ code: CGKeyCode, down: Bool, type: CGEventType? = nil, flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            if let type { event.type = type }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        for modifier in modifiers {
            held.insert(modifier.flag)
            post(modifier.key, down: true, type: .flagsChanged, flags: held)
        }
        post(key, down: true, flags: held.union(extraFlags))
        post(key, down: false, flags: held.union(extraFlags))
        for modifier in modifiers.reversed() {
            held.remove(modifier.flag)
            post(modifier.key, down: false, type: .flagsChanged, flags: held)
        }
    }
}
