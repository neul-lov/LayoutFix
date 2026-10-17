import ClipboardBridge
import HangulLayout

public enum ConversionScope: String, Sendable {
    case selection
    case previousWord
}

public enum WriteMethod: String, Sendable {
    /// Read and written through the Accessibility API.
    case accessibility
    /// Read and selected through Accessibility, written with a clipboard paste.
    case accessibilityWithPaste
    /// No usable Accessibility text: synthetic ⌘C / ⌥⇧← / ⌘V with the clipboard restored after.
    case keyboard
}

/// Why nothing was changed. None of these modify the target text.
public enum RefusalReason: Error, Equatable, Sendable {
    case busy
    case accessibilityPermissionDenied
    case noFrontmostApp
    case ownApp
    case excludedApp
    case unsupportedApp
    case secureInputActive
    case secureField
    case noAccessibleText
    case nothingToConvert
    case unchanged
    case mixedScripts
    case looksLikeEnglish
    case cannotReadSafely
    case textTooLong
    case modifiersStillHeld
    case undoUnavailable
    case undoTargetChanged
    /// The app did not answer Accessibility queries in time (busy or hung).
    case appNotResponding
    case clipboardAccessDenied
    /// The clipboard could not be saved completely (unreadable data, too large, or changing).
    case clipboardNotPreservable
    /// The clipboard holds concealed data such as a password; it is left alone.
    case clipboardHoldsSensitiveData
    /// Keyboard focus moved to another app while the request was running.
    case focusChanged
    /// The text contains an embedded image or file (U+FFFC) that a plain-text write would delete.
    case containsAttachment
    /// The caret is in the middle of a word.
    case caretInsideWord
}

public enum FailureReason: Equatable, Sendable {
    /// The Accessibility API reported an error mid-operation.
    case accessibilityError
    /// The write was accepted but reading back did not show the expected text.
    case replacementNotVerified
    /// The target app never requested the pasted data.
    case pasteNotConfirmed
}

public enum EngineOutcome: Equatable, Sendable {
    case converted(scope: ConversionScope, method: WriteMethod, direction: ResolvedDirection)
    case undone(method: WriteMethod)
    case refused(RefusalReason)
    case failed(FailureReason)

    public var isSuccess: Bool {
        switch self {
        case .converted, .undone: return true
        case .refused, .failed: return false
        }
    }

    /// Short status for the menu. Never contains any of the user's text.
    public var message: String {
        switch self {
        case .converted(let scope, let method, let direction):
            let what = scope == .selection ? "selection" : "previous word"
            let dir = direction == .englishToKorean ? "to Korean" : "to English"
            let how: String
            switch method {
            case .accessibility: how = "Accessibility"
            case .accessibilityWithPaste: how = "Accessibility + paste"
            case .keyboard: how = "clipboard fallback"
            }
            return "Converted \(what) \(dir) (\(how))"
        case .undone:
            return "Restored the original text"
        case .refused(let reason):
            switch reason {
            case .busy: return "Still working on the previous request"
            case .accessibilityPermissionDenied: return "Accessibility permission is required"
            case .noFrontmostApp: return "No active app"
            case .ownApp: return "Ignored inside LayoutFix"
            case .excludedApp: return "Disabled in this app (password manager or system prompt)"
            case .unsupportedApp: return "This app is not supported"
            case .secureInputActive: return "Secure input is on (password field?) — nothing read"
            case .secureField: return "Password field — nothing read"
            case .noAccessibleText: return "No editable text found (clipboard fallback is off)"
            case .nothingToConvert: return "No word before the cursor"
            case .unchanged: return "Nothing to convert"
            case .mixedScripts: return "Mixed Korean and English — choose a direction explicitly"
            case .looksLikeEnglish: return "Looks like English — use English → Korean explicitly"
            case .cannotReadSafely: return "Couldn't read the text safely; nothing changed"
            case .textTooLong: return "Text too long to convert safely"
            case .modifiersStillHeld: return "Release the shortcut keys and try again"
            case .undoUnavailable: return "Nothing to undo"
            case .undoTargetChanged: return "Text changed since conversion; undo skipped"
            case .appNotResponding: return "The app isn't responding; nothing was sent"
            case .clipboardAccessDenied: return "Clipboard access is denied in Privacy & Security; nothing changed"
            case .clipboardNotPreservable: return "Your clipboard couldn't be saved safely; nothing changed"
            case .clipboardHoldsSensitiveData: return "Your clipboard holds a password; clipboard fallback skipped"
            case .focusChanged: return "You switched apps; stopped without changing anything more"
            case .containsAttachment: return "Text contains an image or attachment; nothing changed"
            case .caretInsideWord: return "Cursor is inside a word; select it or move to its end"
            }
        case .failed(let reason):
            switch reason {
            case .accessibilityError: return "The app rejected the change"
            case .replacementNotVerified: return "Couldn't confirm the change in this app"
            case .pasteNotConfirmed: return "Paste was not accepted by this app"
            }
        }
    }
}

extension RefusalReason {
    init(_ unavailable: ClipboardUnavailable) {
        switch unavailable {
        case .accessDenied: self = .clipboardAccessDenied
        case .unreadable, .tooLarge, .changedWhileSaving: self = .clipboardNotPreservable
        case .sensitiveContent: self = .clipboardHoldsSensitiveData
        }
    }

    init(_ refusal: ConversionRefusal) {
        switch refusal {
        case .unchanged: self = .unchanged
        case .mixedScripts: self = .mixedScripts
        case .looksLikeEnglish: self = .looksLikeEnglish
        }
    }
}
