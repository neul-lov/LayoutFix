import Foundation

/// A range in UTF-16 code units, which is what the macOS Accessibility API uses.
public struct UTF16Range: Equatable, Sendable, CustomStringConvertible {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
    public var end: Int { location + length }
    public var description: String { "{\(location), \(length)}" }
}

public struct AppIdentity: Equatable, Sendable {
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let name: String?
    /// Path of the app bundle, used to recognize Electron apps.
    public let bundleURL: URL?

    public init(pid: pid_t, bundleIdentifier: String?, name: String?, bundleURL: URL? = nil) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundleURL = bundleURL
    }
}

public enum TextAccessError: Error, Equatable, Sendable {
    /// The element does not expose this attribute at all.
    case unsupported(String)
    /// The attribute exists but cannot be written.
    case notSettable(String)
    /// The Accessibility API returned an error code (AXError raw value).
    case axFailure(String, Int32)
    /// The value returned had an unexpected type or shape.
    case invalidValue(String)
    /// The app did not answer within the messaging timeout; the request may still be applied.
    case timedOut(String)
}

/// The focused UI element, seen through the operations the engine needs.
/// Every method that touches the target app can fail; callers must check.
@MainActor
public protocol TextElement: AnyObject {
    /// True for password fields and other secure text inputs.
    var isSecure: Bool { get }
    /// A terminal emulator embedded in another app (VS Code's integrated terminal, …), where
    /// ⌥⇧← and ⌘V go to the shell instead of editing text.
    var looksLikeTerminal: Bool { get }
    /// The element exposes a selected text range, i.e. it behaves like editable text.
    var supportsSelection: Bool { get }
    var canSetSelectedRange: Bool { get }
    var canSetSelectedText: Bool { get }

    func selectedRange() throws -> UTF16Range
    func characterCount() throws -> Int
    func string(in range: UTF16Range) throws -> String
    /// The element's own report of the selected text, if it provides one.
    func selectedText() throws -> String?
    func setSelectedRange(_ range: UTF16Range) throws
    /// Replaces the current selection (or inserts at the caret).
    func setSelectedText(_ text: String) throws
    func isSameElement(as other: TextElement) -> Bool
}

/// Result of asking an app for its focused element.
@MainActor
public enum FocusLookup {
    case element(TextElement)
    /// The app answered but has no focused element we can use.
    case none
    /// The app did not answer within the messaging timeout (busy or hung). Keystrokes sent
    /// now would be queued and could run long after we gave up, so nothing should be sent.
    case unresponsive

    public var element: TextElement? {
        if case .element(let e) = self { return e }
        return nil
    }
}

@MainActor
public protocol FocusProviding {
    /// The app that owns keyboard focus. Usually the frontmost app, but a non-activating panel
    /// of another process (Spotlight, for example) can hold focus without being frontmost.
    func frontmostApp() -> AppIdentity?
    func focusedElement(in app: AppIdentity) -> FocusLookup
    /// Whether the app answers Accessibility queries right now. Apps answer them on the same
    /// main thread that handles key events, so a responsive app has processed earlier keys.
    func isResponsive(_ app: AppIdentity) -> Bool
}

/// Permission and system state checks, behind a protocol so tests can deny them.
@MainActor
public protocol SystemStateProviding {
    var isAccessibilityTrusted: Bool { get }
    /// Secure Event Input is on while a password field has focus in most apps, or when an app
    /// like Terminal enables "Secure Keyboard Entry".
    var isSecureInputActive: Bool { get }
}
