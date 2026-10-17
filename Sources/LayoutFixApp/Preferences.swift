import Carbon.HIToolbox
import Foundation
import HangulLayout
import HotKeys

enum HotKeyAction: String, CaseIterable, Identifiable, Codable {
    case convert
    case toKorean
    case toEnglish
    case undo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return "Convert (default direction)"
        case .toKorean: return "Convert English → Korean"
        case .toEnglish: return "Convert Korean → English"
        case .undo: return "Undo last conversion"
        }
    }

    var defaultCombo: KeyCombo {
        let hyper = UInt32(controlKey)
        switch self {
        case .convert: return KeyCombo(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: hyper)
        case .toKorean: return KeyCombo(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: hyper)
        case .toEnglish: return KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: hyper)
        case .undo: return KeyCombo(keyCode: UInt32(kVK_ANSI_Z), carbonModifiers: hyper)
        }
    }
}

extension ConversionDirection {
    var title: String {
        switch self {
        case .auto: return "Auto-detect"
        case .englishToKorean: return "English → Korean (영 → 한)"
        case .koreanToEnglish: return "Korean → English (한 → 영)"
        }
    }

    var explanation: String {
        switch self {
        case .auto:
            return "Hangul becomes keystrokes. Latin letters become Hangul only if no word is a known English word and the result looks like real Korean typing. Mixed text and ambiguous short words (so, go, do…) are left alone; use the explicit shortcuts for those."
        case .englishToKorean:
            return "Always treats Latin letters as Dubeolsik keystrokes."
        case .koreanToEnglish:
            return "Always turns Hangul back into the keys that typed it."
        }
    }
}

/// Settings stored in UserDefaults. Contains only preferences, never any typed text.
struct Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var direction: ConversionDirection {
        get { defaults.string(forKey: "direction").flatMap(ConversionDirection.init(rawValue:)) ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "direction") }
    }

    /// nil value = shortcut deliberately cleared; missing key = default.
    var hotKeys: [HotKeyAction: KeyCombo?] {
        get {
            var result: [HotKeyAction: KeyCombo?] = [:]
            let stored = defaults.data(forKey: "hotKeys")
                .flatMap { try? JSONDecoder().decode([String: KeyCombo?].self, from: $0) } ?? [:]
            for action in HotKeyAction.allCases {
                if let entry = stored[action.rawValue] {
                    result[action] = entry
                } else {
                    result[action] = .some(action.defaultCombo)
                }
            }
            return result
        }
        nonmutating set {
            let encodable = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(encodable), forKey: "hotKeys")
        }
    }

    var allowClipboardFallback: Bool {
        get { defaults.object(forKey: "allowClipboardFallback") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "allowClipboardFallback") }
    }

    var beepOnFailure: Bool {
        get { defaults.object(forKey: "beepOnFailure") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "beepOnFailure") }
    }
}
