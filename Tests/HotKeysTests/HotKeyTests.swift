import AppKit
import Carbon.HIToolbox
import Testing
@testable import HotKeys

@Suite("Key combos")
struct KeyComboTests {
    @Test func display() {
        let combo = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
        #expect(combo.description == "⌃⌥⌘Space")
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey | shiftKey)).description == "⌃⇧K")
    }

    @Test func fromNSEventFlags() {
        let combo = KeyCombo(keyCode: UInt16(kVK_ANSI_E), modifierFlags: [.control, .option, .command, .capsLock])
        #expect(combo == KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(controlKey | optionKey | cmdKey)))
    }

    @Test("Shortcuts that would block typing or app shortcuts are rejected")
    func validation() {
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey)).validationProblem != nil)
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(optionKey)).validationProblem != nil)
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: 0).validationProblem != nil)
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey)).validationProblem == nil)
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(cmdKey | optionKey)).validationProblem == nil)
        #expect(KeyCombo(keyCode: UInt32(kVK_F13), carbonModifiers: 0).validationProblem == nil)
    }

    @Test func codableRoundTrip() throws {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_Z), carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo))
        #expect(decoded == combo)
    }
}

@MainActor
@Suite("Hotkey registration", .serialized)
struct HotKeyManagerTests {
    // Unusual combinations unlikely to be used by anything on the machine.
    static let comboA = KeyCombo(keyCode: UInt32(kVK_F19), carbonModifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
    static let comboB = KeyCombo(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))

    @Test("Registers, reports disabled/invalid/duplicate, and unregisters")
    func registration() {
        let manager = HotKeyManager(systemShortcuts: { [] })
        let results = manager.register([
            ("a", Self.comboA),
            ("b", Self.comboA),
            ("c", nil),
            ("d", KeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey))),
        ])
        #expect(results["a"] == .registered)
        #expect(results["b"] == .duplicate(of: "a"))
        #expect(results["c"] == .disabled)
        if case .invalid = results["d"] {} else { Issue.record("expected invalid, got \(String(describing: results["d"]))") }
        manager.shutdown()
    }

    @Test("A shortcut registered by another owner is detected as in use")
    func conflictWithOtherRegistration() {
        let first = HotKeyManager(systemShortcuts: { [] })
        let second = HotKeyManager(systemShortcuts: { [] })
        #expect(first.register([("x", Self.comboB)])["x"] == .registered)
        #expect(second.register([("y", Self.comboB)])["y"] == .alreadyInUse)
        first.shutdown()
        // Once released it can be taken.
        #expect(second.register([("y", Self.comboB)])["y"] == .registered)
        second.shutdown()
    }

    @Test("Conflicts with enabled macOS shortcuts are reported, not registered")
    func systemConflict() {
        let spotlight = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | optionKey))
        let manager = HotKeyManager(systemShortcuts: { [spotlight] })
        #expect(manager.register([("s", spotlight)])["s"] == .systemShortcutConflict)
        manager.shutdown()
    }

    @Test("Reads the real list of macOS shortcuts")
    func realSystemShortcuts() {
        // Every Mac has some enabled symbolic hotkeys (e.g. ⌘⇧3 screenshot).
        #expect(!SystemShortcuts.enabledCombos().isEmpty)
    }

    @Test("Globe shortcuts (both flag encodings) don't block the plain combo; arrows keep theirs")
    func globeShortcutsIgnored() {
        func entry(_ code: Int, _ mods: Int) -> [String: Any] {
            ["kHISymbolicHotKeyEnabled": true, "kHISymbolicHotKeyCode": code, "kHISymbolicHotKeyModifiers": mods]
        }
        let ctrl = controlKey
        let combos = SystemShortcuts.combos(from: [
            entry(kVK_ANSI_F, ctrl | 0x20000),   // Globe+⌃F (fill window), Carbon flag
            entry(kVK_ANSI_R, ctrl | 0x800000),  // Globe+⌃R, CGEvent flag
            entry(kVK_LeftArrow, ctrl | 0x20000), // ⌃← (Mission Control), flag is noise
            entry(kVK_Space, ctrl | optionKey),  // ⌃⌥Space (next input source)
        ])
        #expect(!combos.contains(KeyCombo(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(ctrl))))
        #expect(!combos.contains(KeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(ctrl))))
        #expect(combos.contains(KeyCombo(keyCode: UInt32(kVK_LeftArrow), carbonModifiers: UInt32(ctrl))))
        #expect(combos.contains(KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(ctrl | optionKey))))
    }
}
