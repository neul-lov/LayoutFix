import Foundation
import AccessibilityText
import ClipboardBridge
import ConversionEngine

/// A text field in a pretend app: text plus selection, in UTF-16 units like AX.
@MainActor
final class FakeDocument {
    var text: String
    var selection: UTF16Range

    init(_ text: String, selection: UTF16Range? = nil) {
        self.text = text
        self.selection = selection ?? UTF16Range(location: text.utf16.count, length: 0)
    }

    /// Convenience: "abc|def" puts the caret at "|", "ab[cd]ef" selects "cd".
    convenience init(marked: String) {
        let ns = marked as NSString
        if ns.range(of: "[").location != NSNotFound {
            let open = ns.range(of: "[").location
            let stripped = ns.replacingOccurrences(of: "[", with: "") as NSString
            let close = stripped.range(of: "]").location
            self.init(stripped.replacingOccurrences(of: "]", with: ""), selection: UTF16Range(location: open, length: close - open))
        } else {
            let caret = ns.range(of: "|").location
            self.init(ns.replacingOccurrences(of: "|", with: ""), selection: UTF16Range(location: caret, length: 0))
        }
    }

    /// Inverse of `init(marked:)`.
    var marked: String {
        let ns = text as NSString
        let before = ns.substring(to: selection.location)
        let inside = ns.substring(with: NSRange(location: selection.location, length: selection.length))
        let after = ns.substring(from: selection.end)
        return selection.length == 0 ? before + "|" + after : before + "[" + inside + "]" + after
    }

    var selectedString: String {
        (text as NSString).substring(with: NSRange(location: selection.location, length: selection.length))
    }

    func replaceSelection(with s: String) {
        text = (text as NSString).replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: s)
        selection = UTF16Range(location: selection.location + s.utf16.count, length: 0)
    }
}

/// Accessibility view of a FakeDocument, with switches for app quirks.
@MainActor
final class FakeTextElement: TextElement {
    let doc: FakeDocument
    var isSecure = false
    var looksLikeTerminal = false
    var supportsSelection = true
    var canSetSelectedRange = true
    var canSetSelectedText = true
    /// The app reports success for writes but does nothing (seen in some apps).
    var ignoresTextWrites = false
    /// The app reports a selected text that differs from the range contents.
    var reportsWrongSelectedText = false
    /// The write is accepted now but applied this many polls later.
    var appliesWritesAfterPolls = 0
    /// The write call times out (throws) although the app still applies it.
    var timesOutButApplies = false
    private var pendingWrite: (text: String, polls: Int)?
    private(set) var readCount = 0
    private(set) var writeCount = 0

    init(_ doc: FakeDocument) { self.doc = doc }

    func selectedRange() throws -> UTF16Range { readCount += 1; return doc.selection }
    func characterCount() throws -> Int { readCount += 1; return doc.text.utf16.count }

    func string(in range: UTF16Range) throws -> String {
        readCount += 1
        guard range.location >= 0, range.end <= doc.text.utf16.count else { throw TextAccessError.invalidValue("range") }
        return (doc.text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }

    func selectedText() throws -> String? {
        readCount += 1
        return reportsWrongSelectedText ? "something else" : doc.selectedString
    }

    func setSelectedRange(_ range: UTF16Range) throws {
        guard canSetSelectedRange else { throw TextAccessError.notSettable("range") }
        doc.selection = range
    }

    func setSelectedText(_ text: String) throws {
        guard canSetSelectedText else { throw TextAccessError.notSettable("text") }
        writeCount += 1
        if ignoresTextWrites { return }
        if appliesWritesAfterPolls > 0 {
            pendingWrite = (text, appliesWritesAfterPolls)
            return
        }
        doc.replaceSelection(with: text)
        if timesOutButApplies { throw TextAccessError.timedOut("text") }
    }

    func tick() {
        guard let pending = pendingWrite else { return }
        if pending.polls <= 1 {
            pendingWrite = nil
            doc.replaceSelection(with: pending.text)
        } else {
            pendingWrite = (pending.text, pending.polls - 1)
        }
    }

    func isSameElement(as other: TextElement) -> Bool { other === self }
}

@MainActor
final class FakeFocus: FocusProviding {
    var app: AppIdentity?
    var element: TextElement?
    /// Simulates an app that does not answer Accessibility queries in time.
    var unresponsive = false
    /// Answers isResponsive (the keyboard fake reports whether it is busy).
    var responsiveCheck: () -> Bool = { true }
    init(app: AppIdentity?, element: TextElement?) { self.app = app; self.element = element }
    func frontmostApp() -> AppIdentity? { app }
    func focusedElement(in app: AppIdentity) -> FocusLookup {
        if unresponsive { return .unresponsive }
        return element.map { .element($0) } ?? .none
    }
    func isResponsive(_ app: AppIdentity) -> Bool { !unresponsive && responsiveCheck() }
}

@MainActor
final class FakeSystem: SystemStateProviding {
    var isAccessibilityTrusted = true
    var isSecureInputActive = false
}

final class FakeHandle: PasteWriteHandle, @unchecked Sendable {
    var wasRead = false
}

@MainActor
final class FakePasteboard: PasteboardAccessing {
    private(set) var changeCount = 0
    private(set) var items: [[PasteboardEntry]] = []
    private var pendingHandle: FakeHandle?
    /// Makes the next snapshots fail the way the real pasteboard can.
    var snapshotFailure: ClipboardUnavailable?
    /// Number of writes LayoutFix made (transient text or restores).
    private(set) var writesByEngine = 0

    init(initial: String? = nil) {
        if let initial { setUserString(initial) }
    }

    func snapshot() throws(ClipboardUnavailable) -> PasteboardSnapshot {
        if let snapshotFailure { throw snapshotFailure }
        return PasteboardSnapshot(items: items)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        items = snapshot.items
        pendingHandle = nil
        changeCount += 1
        writesByEngine += 1
    }

    func readString() -> String? {
        data(forType: "public.utf8-plain-text").flatMap { String(data: $0, encoding: .utf8) }
    }

    func data(forType type: String) -> Data? { items.first?.first { $0.type == type }?.data }

    func writeTransientString(_ text: String) -> PasteWriteHandle {
        let handle = FakeHandle()
        items = [[PasteboardEntry(type: "public.utf8-plain-text", data: Data(text.utf8)),
                  PasteboardEntry(type: PasteboardMarkers.transient, data: Data())]]
        pendingHandle = handle
        changeCount += 1
        writesByEngine += 1
        return handle
    }

    /// What another app (or the user) copying something looks like.
    func setUserString(_ s: String, extraTypes: [String: Data] = [:]) {
        var item = [PasteboardEntry(type: "public.utf8-plain-text", data: Data(s.utf8)),
                    PasteboardEntry(type: "public.rtf", data: Data("{\\rtf1 \(s)}".utf8))]
        item += extraTypes.sorted { $0.key < $1.key }.map { PasteboardEntry(type: $0.key, data: $0.value) }
        items = [item]
        pendingHandle = nil
        changeCount += 1
    }

    /// Target app reading the clipboard on paste.
    func appReadString() -> String? {
        pendingHandle?.wasRead = true
        return readString()
    }
}

/// A pretend app that reacts to the synthetic keystrokes like a Cocoa text view.
@MainActor
final class FakeKeyboardApp: KeystrokeSending {
    let doc: FakeDocument
    let pasteboard: FakePasteboard
    var modifiersHeldForPolls = 0
    var supportsCopy = true
    var supportsPaste = true
    enum EmptyCopyStyle { case none, lineWithVSCodeMarker, lineWithoutMarker }
    var emptySelectionCopy: EmptyCopyStyle = .none
    private(set) var log: [String] = []
    /// The app does not process events for this many polls; events queue up meanwhile.
    var busyForPolls = 0
    private var queued: [() -> Void] = []

    init(doc: FakeDocument, pasteboard: FakePasteboard) {
        self.doc = doc
        self.pasteboard = pasteboard
    }

    func modifiersReleased() -> Bool {
        if modifiersHeldForPolls > 0 { modifiersHeldForPolls -= 1; return false }
        return true
    }

    func tick() {
        guard busyForPolls > 0 else { return }
        busyForPolls -= 1
        if busyForPolls == 0 {
            let events = queued
            queued.removeAll()
            events.forEach { $0() }
        }
    }

    /// Runs `event` now, or queues it while the app is busy.
    private func handle(_ event: @escaping () -> Void) {
        if busyForPolls > 0 { queued.append(event) } else { event() }
    }

    func copy() {
        log.append("copy")
        handle { [self] in performCopy() }
    }

    private func performCopy() {
        guard supportsCopy else { return }
        if doc.selection.length > 0 {
            pasteboard.setUserString(doc.selectedString)
            return
        }
        let line = currentLine() + "\n"
        switch emptySelectionCopy {
        case .none: break
        case .lineWithoutMarker: pasteboard.setUserString(line)
        case .lineWithVSCodeMarker:
            let marker = try! JSONSerialization.data(withJSONObject: ["isFromEmptySelection": true])
            pasteboard.setUserString(line, extraTypes: ["vscode-editor-data": marker])
        }
    }

    /// The app is stalled: ⌘V is queued and handled only when `deliverQueuedPaste()` runs.
    var stalledPaste = false
    private var queuedPaste = false

    func paste() {
        log.append("paste")
        if stalledPaste { queuedPaste = true; return }
        handle { [self] in
            guard supportsPaste, let s = pasteboard.appReadString() else { return }
            doc.replaceSelection(with: s)
        }
    }

    /// The stalled app finally handles the ⌘V it had queued, with whatever is on the clipboard now.
    func deliverQueuedPaste() {
        guard queuedPaste else { return }
        queuedPaste = false
        if let s = pasteboard.appReadString() { doc.replaceSelection(with: s) }
    }

    func selectWordBackward() {
        log.append("selectWordBackward")
        handle { [self] in performSelectWordBackward() }
    }

    private func performSelectWordBackward() {
        let ns = doc.text as NSString
        let caret = doc.selection.end
        var start = caret
        // Like ⌥←: skip whitespace (including line breaks), then the word.
        while start > 0, isSpace(ns.character(at: start - 1)) { start -= 1 }
        while start > 0, !isSpace(ns.character(at: start - 1)) { start -= 1 }
        doc.selection = UTF16Range(location: start, length: caret - start)
    }

    func extendSelectionBackward(characters: Int) {
        log.append("extendSelectionBackward(\(characters))")
        let end = doc.selection.end
        var startIndex = String.Index(utf16Offset: doc.selection.location, in: doc.text)
        for _ in 0..<characters where startIndex > doc.text.startIndex {
            startIndex = doc.text.index(before: startIndex)
        }
        let start = startIndex.utf16Offset(in: doc.text)
        doc.selection = UTF16Range(location: start, length: end - start)
    }

    func collapseSelectionToEnd() {
        log.append("collapse")
        handle { [self] in performCollapse() }
    }

    private func performCollapse() {
        if doc.selection.length > 0 {
            doc.selection = UTF16Range(location: doc.selection.end, length: 0)
        } else {
            // Like →: with no selection the caret moves. Tests use this to catch unwanted moves.
            doc.selection.location = min(doc.selection.location + 1, doc.text.utf16.count)
        }
    }

    private func isSpace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return scalar.properties.isWhitespace
    }

    private func currentLine() -> String {
        let ns = doc.text as NSString
        return ns.substring(with: ns.lineRange(for: NSRange(location: doc.selection.location, length: 0)))
            .trimmingCharacters(in: .newlines)
    }
}

@MainActor
final class FakeSleeper: Sleeping {
    var onSleep: ((Int) -> Void)?
    /// Advances the fake apps' clocks (busy apps, delayed writes).
    var ticker: (() -> Void)?
    private(set) var count = 0
    func sleep(seconds: Double) async {
        count += 1
        ticker?()
        onSleep?(count)
        await Task.yield()
    }
}

/// Wires a complete engine around one fake document.
@MainActor
struct Harness {
    let doc: FakeDocument
    let element: FakeTextElement
    let focus: FakeFocus
    let system = FakeSystem()
    let pasteboard: FakePasteboard
    let keyboard: FakeKeyboardApp
    let sleeper = FakeSleeper()
    let clock: TestClock
    let engine: ConversionEngine

    static let notes = AppIdentity(pid: 1001, bundleIdentifier: "com.apple.Notes", name: "Notes")

    init(_ marked: String, accessibility: Bool = true, app: AppIdentity = Harness.notes,
         clipboard: String? = "user clipboard", settings: EngineSettings = EngineSettings()) {
        doc = FakeDocument(marked: marked)
        element = FakeTextElement(doc)
        focus = FakeFocus(app: app, element: accessibility ? element : nil)
        pasteboard = FakePasteboard(initial: clipboard)
        keyboard = FakeKeyboardApp(doc: doc, pasteboard: pasteboard)
        clock = TestClock()
        let clock = clock
        let keyboard = keyboard
        let element = element
        focus.responsiveCheck = { keyboard.busyForPolls == 0 }
        sleeper.ticker = { keyboard.tick(); element.tick() }
        engine = ConversionEngine(focus: focus, system: system, pasteboard: pasteboard, keys: keyboard,
                                  settings: settings, sleeper: sleeper, now: { clock.now }, ownPID: 99)
    }
}

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}
