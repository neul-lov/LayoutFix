import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ClipboardBridge

/// Low-level Accessibility helpers used to set up and inspect test state in real apps.
/// (The engine under test uses its own AX layer; these exist only to arrange and assert.)
@MainActor
enum AX {
    static func appElement(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 1.0)
        return el
    }

    static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attribute(el, name) as? String }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func focused(_ pid: pid_t) -> AXUIElement? { element(appElement(pid), kAXFocusedUIElementAttribute) }

    static func value(_ el: AXUIElement) -> String? { string(el, kAXValueAttribute) }

    @discardableResult
    static func setValue(_ el: AXUIElement, _ s: String) -> AXError {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, s as CFString)
    }

    static func range(_ el: AXUIElement) -> (Int, Int)? {
        guard let v = attribute(el, kAXSelectedTextRangeAttribute) else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return (r.location, r.length)
    }

    @discardableResult
    static func setRange(_ el: AXUIElement, _ location: Int, _ length: Int) -> AXError {
        var r = CFRange(location: location, length: length)
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!)
    }

    @discardableResult
    static func setBool(_ el: AXUIElement, _ name: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(el, name as CFString, value as CFBoolean)
    }

    @discardableResult
    static func press(_ el: AXUIElement) -> AXError { AXUIElementPerformAction(el, kAXPressAction as CFString) }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attribute(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Breadth-first search, bounded so a huge tree cannot hang the harness.
    static func find(in root: AXUIElement, maxNodes: Int = 4000, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let el = queue.removeFirst()
            visited += 1
            if match(el) { return el }
            queue.append(contentsOf: children(el))
        }
        return nil
    }
}

@MainActor
enum Keys {
    static func tap(_ key: Int, _ flags: CGEventFlags = []) {
        // Same as a person: modifier keys down, key, modifier keys up (never leave ⌘ "held").
        let all: [(Int, CGEventFlags)] = [(kVK_Control, .maskControl), (kVK_Option, .maskAlternate),
                                          (kVK_Shift, .maskShift), (kVK_Command, .maskCommand)]
        let modifiers = all.filter { flags.contains($0.1) }
        let extra = flags.subtracting([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        chord(key, modifiers: modifiers, extraFlags: extra)
    }

    /// True if the system currently believes a modifier key is held.
    static var anyModifierHeld: Bool {
        !CGEventSource.flagsState(.hidSystemState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    /// Modifier key downs (accumulating flags), the key, then modifier key ups.
    static func chord(_ key: Int, modifiers: [(Int, CGEventFlags)], extraFlags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        func post(_ code: Int, _ down: Bool, _ flagsNow: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)!
            e.flags = flagsNow
            e.post(tap: .cghidEventTap)
        }
        for (code, flag) in modifiers {
            flags.insert(flag)
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)!
            e.type = .flagsChanged
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        post(key, true, flags.union(extraFlags))
        post(key, false, flags.union(extraFlags))
        for (code, flag) in modifiers.reversed() {
            flags.remove(flag)
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)!
            e.type = .flagsChanged
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Types text as Unicode key events, independent of the active input source.
    static func type(_ text: String) async {
        let source = CGEventSource(stateID: .privateState)
        for ch in text {
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)!
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
}

@MainActor
func sleep(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
}

@MainActor
func waitFor(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        await sleep(0.05)
    }
    return condition()
}

@MainActor
func frontmostBundleID() -> String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

/// Thrown when the user (or anything else) moves focus away from the app under test.
struct FocusLost: Error {
    let expected: String
    let actual: String?
}

/// Every engine call and synthetic keystroke in the harness goes through this check, so a
/// focus change never sends test input to whatever app the user switched to.
@MainActor
func requireFront(_ bundleID: String) throws {
    let front = frontmostBundleID()
    guard front == bundleID else { throw FocusLost(expected: bundleID, actual: front) }
}

/// Opens `url` in the app and waits until it is frontmost. Falls back to AXFrontmost.
@MainActor
func openAndActivate(_ url: URL?, bundleID: String) async -> NSRunningApplication? {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    // NSWorkspace.open from this background process silently failed to load documents in
    // Safari; /usr/bin/open goes through LaunchServices the same way a user's double-click does.
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-a", appURL.path] + (url.map { [$0.path] } ?? [])
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        print("  ·     open failed: \(error.localizedDescription)")
    }
    // The returned NSRunningApplication can be a placeholder (pid -1); look it up instead.
    func resolved() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { $0.processIdentifier > 0 }
    }
    _ = await waitFor(8) { resolved() != nil }
    guard let running = resolved() else { return nil }
    await sleep(0.5)
    return await activate(running) ? running : nil
}

/// macOS cooperative activation ignores activation requests from a background process,
/// so bring the app forward through Accessibility instead.
@MainActor
func activate(_ app: NSRunningApplication) async -> Bool {
    guard let bundleID = app.bundleIdentifier, app.processIdentifier > 0 else { return false }
    for _ in 0..<4 {
        if frontmostBundleID() == bundleID { return true }
        let el = AX.appElement(app.processIdentifier)
        AX.setBool(el, kAXFrontmostAttribute, true)
        if let window = (AX.attribute(el, kAXWindowsAttribute) as? [AXUIElement])?.first {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AX.setBool(window, kAXMainAttribute, true)
        }
        if await waitFor(2, { frontmostBundleID() == bundleID }) { return true }
    }
    return false
}

/// Safari tab handling for the test pages. Only tabs whose title starts with one of our test
/// prefixes are touched, and ⌘W is sent only after confirming the active tab is such a tab.
@MainActor
enum SafariTabs {
    static let testPrefixes = ["LayoutFix Test Page", "LayoutFix Hotkey Test"]

    static func isTestTitle(_ title: String?, prefix: String) -> Bool {
        title?.hasPrefix(prefix) == true
    }

    /// Searches each window separately, so a large page in one window cannot use up the
    /// node budget before another window's tab bar is reached.
    static func tabButtons(_ root: AXUIElement, prefix: String) -> [AXUIElement] {
        var found: [AXUIElement] = []
        for window in (AX.attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            _ = AX.find(in: window, maxNodes: 4000) { el in
                if AX.string(el, kAXSubroleAttribute) == "AXTabButton", isTestTitle(AX.string(el, kAXTitleAttribute), prefix: prefix) {
                    found.append(el)
                }
                return false
            }
        }
        return found
    }

    /// The main (document) window. The "focused" window can be a floating helper such as
    /// Safari's autocorrect bubble (subrole AXUnknown), so it is not used.
    static func focusedWindow(_ root: AXUIElement) -> AXUIElement? {
        AX.element(root, kAXMainWindowAttribute) ?? AX.element(root, kAXFocusedWindowAttribute)
    }

    static func activeTitle(_ root: AXUIElement) -> String? {
        focusedWindow(root).flatMap { AX.string($0, kAXTitleAttribute) }
    }

    /// The window containing `element`, found by walking up the parent chain.
    static func window(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let el = current else { return nil }
            if AX.string(el, kAXRoleAttribute) == kAXWindowRole { return el }
            current = AX.element(el, kAXParentAttribute)
        }
        return nil
    }

    /// Makes a test tab the active tab of the focused window. Safari may open a file as a
    /// background tab, and background tabs expose no page content to Accessibility.
    static func activate(_ root: AXUIElement, prefix: String) async -> Bool {
        if isTestTitle(activeTitle(root), prefix: prefix) { return true }
        for tab in tabButtons(root, prefix: prefix) {
            if let window = window(of: tab) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AX.setBool(window, kAXMainAttribute, true)
                AX.setBool(window, kAXFocusedAttribute, true)
            }
            AX.press(tab)
            if await waitFor(2, { isTestTitle(activeTitle(root), prefix: prefix) }) { return true }
        }
        return isTestTitle(activeTitle(root), prefix: prefix)
    }

    /// Closes every test tab with this prefix through that tab's own "Close Tab" action, so
    /// no keystroke is involved and no other tab can be affected.
    static func closeAll(_ root: AXUIElement, prefix: String) async -> Int {
        var closed = 0
        for tab in tabButtons(root, prefix: prefix) {
            var names: CFArray?
            if AXUIElementCopyActionNames(tab, &names) == .success,
               let close = (names as? [String])?.first(where: { $0.contains("_closeButtonClicked:") }) {
                if AXUIElementPerformAction(tab, close as CFString) == .success { closed += 1 }
            } else if closeWindowHoldingOnly(tab, root: root, prefix: prefix) {
                closed += 1
            }
            await sleep(0.3)
        }
        return closed
    }

    /// Safari offers no "Close Tab" for the last regular tab of a window. Close that window,
    /// but only if every other tab in it is a pinned tab present in all other windows too.
    private static func closeWindowHoldingOnly(_ tab: AXUIElement, root: AXUIElement, prefix: String) -> Bool {
        guard let window = window(of: tab) else { return false }
        let windows = ((AX.attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [])
            .filter { AX.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
        func titles(_ w: AXUIElement) -> [String] {
            var result: [String] = []
            _ = AX.find(in: w, maxNodes: 4000) { el in
                if AX.string(el, kAXSubroleAttribute) == "AXTabButton" { result.append(AX.string(el, kAXTitleAttribute) ?? "") }
                return false
            }
            return result
        }
        let others = windows.filter { !CFEqual($0, window) }
        guard !others.isEmpty else { return false }
        let shared = others.map { Set(titles($0)) }.reduce(into: Set(titles(others[0]))) { $0.formIntersection($1) }
        let mine = titles(window).filter { !isTestTitle($0, prefix: prefix) }
        guard mine.allSatisfy(shared.contains), let close = AX.element(window, kAXCloseButtonAttribute) else { return false }
        return AX.press(close) == .success
    }

    /// Finds an element by DOM id inside the focused window only, never in stale tabs.
    static func element(_ root: AXUIElement, domID: String) -> AXUIElement? {
        guard let window = focusedWindow(root) else { return nil }
        return AX.find(in: window, maxNodes: 6000) { AX.string($0, "AXDOMIdentifier") == domID }
    }
}

/// Reporter. Prints only synthetic test strings, never anything typed by the user.
@MainActor
final class Report {
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0

    func section(_ title: String) { print("\n=== \(title)") }

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            print("  PASS  \(name)")
        } else {
            failed += 1
            let d = detail()
            print("  FAIL  \(name)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    func skip(_ name: String, _ reason: String) {
        skipped += 1
        print("  SKIP  \(name) — \(reason)")
    }

    func note(_ text: String) { print("  ·     \(text)") }
}

/// Guards the user's real clipboard across the whole run.
@MainActor
final class ClipboardGuard {
    private let pasteboard = SystemPasteboard()
    private let saved: PasteboardSnapshot?

    init() { saved = try? pasteboard.snapshot() }

    var isUnchanged: Bool { saved != nil && (try? pasteboard.snapshot()) == saved }

    func restoreIfChanged() {
        if let saved, !isUnchanged { pasteboard.restore(saved) }
    }
}
