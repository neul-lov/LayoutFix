import Carbon.HIToolbox
import Foundation

public enum HotKeyRegistrationResult: Equatable, Sendable {
    case registered
    case disabled
    case invalid(String)
    /// The same combination is assigned to another action in this app.
    case duplicate(of: String)
    /// An enabled macOS keyboard shortcut (Spotlight, input source switching, …) uses it.
    case systemShortcutConflict
    /// Another app has registered it exclusively.
    case alreadyInUse
    case failed(OSStatus)

    public var isProblem: Bool {
        switch self {
        case .registered, .disabled: return false
        default: return true
        }
    }

    public var message: String {
        switch self {
        case .registered: return "Active"
        case .disabled: return "Not set"
        case .invalid(let reason): return reason
        case .duplicate(let other): return "Same shortcut as “\(other)”."
        case .systemShortcutConflict: return "Used by a macOS keyboard shortcut (System Settings › Keyboard › Keyboard Shortcuts)."
        case .alreadyInUse: return "Already registered by another app."
        case .failed(let status): return "Registration failed (error \(status))."
        }
    }
}

/// Registers global hotkeys with Carbon's `RegisterEventHotKey`.
///
/// This is still the supported way to get a system-wide shortcut that is delivered while
/// other apps are frontmost. It needs no Accessibility permission, involves no event tap,
/// and costs nothing while idle: the window server delivers an event only on a match.
@MainActor
public final class HotKeyManager {
    public var onPress: ((String) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var names: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private let systemShortcuts: () -> Set<KeyCombo>
    nonisolated private static let signature: OSType = 0x4C46_6978 // 'LFix'

    public init(systemShortcuts: @escaping () -> Set<KeyCombo> = SystemShortcuts.enabledCombos) {
        self.systemShortcuts = systemShortcuts
    }

    /// Replaces all registrations. Bindings are processed in order, so for duplicates the
    /// first action keeps the shortcut.
    @discardableResult
    public func register(_ bindings: [(name: String, combo: KeyCombo?)]) -> [String: HotKeyRegistrationResult] {
        unregisterAll()
        var results: [String: HotKeyRegistrationResult] = [:]

        let handlerStatus = installHandlerIfNeeded()
        let system = systemShortcuts()
        var taken: [KeyCombo: String] = [:]

        for (name, combo) in bindings {
            guard let combo else { results[name] = .disabled; continue }
            if let problem = combo.validationProblem { results[name] = .invalid(problem); continue }
            if let other = taken[combo] { results[name] = .duplicate(of: other); continue }
            if system.contains(combo) { results[name] = .systemShortcutConflict; continue }
            guard handlerStatus == noErr else { results[name] = .failed(handlerStatus); continue }

            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode, combo.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            switch (status, ref) {
            case (noErr, .some(let ref)):
                refs[id] = ref
                names[id] = name
                taken[combo] = name
                results[name] = .registered
            case (OSStatus(eventHotKeyExistsErr), _):
                results[name] = .alreadyInUse
            default:
                results[name] = .failed(status)
            }
        }
        return results
    }

    public func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        names.removeAll()
    }

    /// Unregisters everything and removes the Carbon event handler. Call on quit.
    public func shutdown() {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    private func installHandlerIfNeeded() -> OSStatus {
        if handlerRef != nil { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            // Carbon dispatches hotkey events on the main thread.
            MainActor.assumeIsolated { manager.handle(id: hotKeyID.id) }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }

    private func handle(id: UInt32) {
        guard let name = names[id] else { return }
        onPress?(name)
    }
}

/// Enabled macOS keyboard shortcuts ("symbolic hot keys") such as Spotlight (⌘Space) or
/// input source switching (⌃Space), read through Carbon's `CopySymbolicHotKeys`.
public enum SystemShortcuts {
    public static func enabledCombos() -> Set<KeyCombo> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return combos(from: list)
    }

    /// Globe/fn flag as reported by `CopySymbolicHotKeys`: either the Carbon bit
    /// (kEventKeyModifierFnMask, 0x20000) or the CGEvent bit (0x800000), depending on the macOS version.
    static let globeMask: UInt32 = 0x20000 | 0x800000

    static func combos(from list: [[String: Any]]) -> Set<KeyCombo> {
        var combos = Set<KeyCombo>()
        for entry in list {
            // The key constants are CFSTR macros, which Swift does not import.
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let mods = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { continue }
            // Arrow, F- and navigation keys always carry the Globe flag, so for them it is noise.
            // On any other key it means the shortcut needs Globe (e.g. Globe+⌃F to fill a
            // window), which a plain ⌃F can never trigger.
            if mods & globeMask != 0, !KeyNames.inherentlyFunctionKeys.contains(Int(code)) { continue }
            combos.insert(KeyCombo(keyCode: code, carbonModifiers: mods))
        }
        return combos
    }
}
