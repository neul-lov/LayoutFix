import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// `TextElement` backed by the macOS Accessibility API.
///
/// Each call is a synchronous IPC round trip to the target app, so every element gets a
/// short messaging timeout: an unresponsive app makes the call fail instead of hanging.
@MainActor
public final class AXTextElement: TextElement {
    static let messagingTimeout: Float = 0.5

    let element: AXUIElement
    public let role: String?
    public let subrole: String?
    public let isSecure: Bool
    public let supportsSelection: Bool
    public let canSetSelectedRange: Bool
    public let canSetSelectedText: Bool
    /// A query hit the messaging timeout: the app is busy or hung.
    public let timedOut: Bool
    public let looksLikeTerminal: Bool
    private let supportsStringForRange: Bool

    public init(_ element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)

        var roleValue: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        role = roleValue as? String
        subrole = Self.copyString(element, kAXSubroleAttribute)
        isSecure = subrole == kAXSecureTextFieldSubrole || role == kAXSecureTextFieldSubrole

        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        timedOut = roleError == .cannotComplete || rangeError == .cannotComplete
        // xterm.js (VS Code, Cursor, Hyper, Tabby) labels its input "Terminal input" and the
        // like; JetBrains uses a "Terminal" role description.
        let labels = [kAXDescriptionAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
            .compactMap { Self.copyString(element, $0)?.lowercased() }
        looksLikeTerminal = labels.contains { $0.contains("terminal") }
        supportsSelection = rangeError == .success
            && rangeValue.map { CFGetTypeID($0) == AXValueGetTypeID() } == true
        canSetSelectedRange = supportsSelection && Self.isSettable(element, kAXSelectedTextRangeAttribute)
        canSetSelectedText = supportsSelection && Self.isSettable(element, kAXSelectedTextAttribute)

        var names: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &names) == .success, let list = names as? [String] {
            supportsStringForRange = list.contains(kAXStringForRangeParameterizedAttribute)
        } else {
            supportsStringForRange = false
        }
    }

    public func selectedRange() throws -> UTF16Range {
        let value = try copyValue(kAXSelectedTextRangeAttribute)
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw TextAccessError.invalidValue(kAXSelectedTextRangeAttribute) }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            throw TextAccessError.invalidValue(kAXSelectedTextRangeAttribute)
        }
        return UTF16Range(location: range.location, length: range.length)
    }

    public func characterCount() throws -> Int {
        if let value = try? copyValue(kAXNumberOfCharactersAttribute), let number = value as? NSNumber {
            return number.intValue
        }
        return try fullValue().utf16.count
    }

    public func string(in range: UTF16Range) throws -> String {
        if range.length == 0 { return "" }
        if supportsStringForRange {
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let param = AXValueCreate(.cfRange, &cfRange) else { throw TextAccessError.invalidValue("range") }
            var result: CFTypeRef?
            let err = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &result)
            if err == .success, let s = result as? String { return s }
            // Some apps advertise the attribute but fail for some ranges; fall back to the value.
        }
        let utf16 = try fullValue().utf16
        guard range.location >= 0, range.end <= utf16.count else {
            throw TextAccessError.invalidValue("range out of bounds")
        }
        let start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let end = utf16.index(start, offsetBy: range.length)
        guard let s = String(utf16[start..<end]) else {
            throw TextAccessError.invalidValue("range splits a character")
        }
        return s
    }

    public func selectedText() throws -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        switch err {
        case .success: return value as? String
        case .attributeUnsupported, .noValue: return nil
        default: throw TextAccessError.axFailure(kAXSelectedTextAttribute, err.rawValue)
        }
    }

    public func setSelectedRange(_ range: UTF16Range) throws {
        guard canSetSelectedRange else { throw TextAccessError.notSettable(kAXSelectedTextRangeAttribute) }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { throw TextAccessError.invalidValue("range") }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        guard err == .success else { throw TextAccessError.axFailure(kAXSelectedTextRangeAttribute, err.rawValue) }
    }

    public func setSelectedText(_ text: String) throws {
        guard canSetSelectedText else { throw TextAccessError.notSettable(kAXSelectedTextAttribute) }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if err == .cannotComplete { throw TextAccessError.timedOut(kAXSelectedTextAttribute) }
        guard err == .success else { throw TextAccessError.axFailure(kAXSelectedTextAttribute, err.rawValue) }
    }

    public func isSameElement(as other: TextElement) -> Bool {
        guard let other = other as? AXTextElement else { return false }
        return CFEqual(element, other.element)
    }

    // MARK: Helpers

    private func fullValue() throws -> String {
        let value = try copyValue(kAXValueAttribute)
        guard let s = value as? String else { throw TextAccessError.invalidValue(kAXValueAttribute) }
        return s
    }

    private func copyValue(_ attribute: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch err {
        case .success:
            guard let value else { throw TextAccessError.invalidValue(attribute) }
            return value
        case .attributeUnsupported, .noValue:
            throw TextAccessError.unsupported(attribute)
        default:
            throw TextAccessError.axFailure(attribute, err.rawValue)
        }
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }
}

/// Finds the focused element of the frontmost app.
@MainActor
public struct AXFocusProvider: FocusProviding {
    public init() {}

    public func frontmostApp() -> AppIdentity? {
        // Ask Accessibility which app holds keyboard focus; Spotlight and other non-activating
        // panels take focus without becoming the frontmost app.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, AXTextElement.messagingTimeout)
        if case .found(let focusedApp) = Self.copyElement(systemWide, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focusedApp, &pid) == .success, let app = NSRunningApplication(processIdentifier: pid) {
                return Self.identity(app)
            }
        }
        return NSWorkspace.shared.frontmostApplication.map(Self.identity)
    }

    public func focusedElement(in app: AppIdentity) -> FocusLookup {
        let appElement = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(appElement, AXTextElement.messagingTimeout)
        switch Self.copyElement(appElement, kAXFocusedUIElementAttribute) {
        case .found(let focused):
            let element = AXTextElement(focused)
            return element.timedOut ? .unresponsive : .element(element)
        case .timedOut:
            return .unresponsive
        case .missing:
            break
        }
        // Some apps only answer through the system-wide element.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, AXTextElement.messagingTimeout)
        if case .found(let focused) = Self.copyElement(systemWide, kAXFocusedUIElementAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focused, &pid) == .success, pid == app.pid {
                let element = AXTextElement(focused)
                return element.timedOut ? .unresponsive : .element(element)
            }
        }
        return .none
    }

    public func isResponsive(_ app: AppIdentity) -> Bool {
        let appElement = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(appElement, AXTextElement.messagingTimeout)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &value) != .cannotComplete
    }

    private static func identity(_ app: NSRunningApplication) -> AppIdentity {
        AppIdentity(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                    name: app.localizedName, bundleURL: app.bundleURL)
    }

    private enum ElementQuery {
        case found(AXUIElement)
        case timedOut
        case missing
    }

    private static func copyElement(_ parent: AXUIElement, _ attribute: String) -> ElementQuery {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .missing }
            return .found(value as! AXUIElement)
        case .cannotComplete:
            return .timedOut
        default:
            return .missing
        }
    }
}

@MainActor
public struct SystemState: SystemStateProviding {
    public init() {}
    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    public var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
}

public enum AccessibilityPermission {
    /// Shows the system prompt that offers to open Privacy & Security settings.
    /// The process is added to the Accessibility list (unchecked) as a side effect.
    @MainActor
    public static func requestWithSystemPrompt() {
        // Value of kAXTrustedCheckOptionPrompt; the global is not concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Posted (undocumented but long-standing) when any app's Accessibility permission changes.
    public static let changedNotification = Notification.Name("com.apple.accessibility.api")
}
