import Foundation
import HangulLayout
import AccessibilityText
import ClipboardBridge

public struct EngineSettings: Sendable {
    /// Allow the ⌘C/⌘V path when an app has no usable Accessibility text.
    public var allowClipboardFallback = true
    /// How long the undo record is kept in memory.
    public var undoLifetime: TimeInterval = 120
    /// Longest selection converted, in UTF-16 units.
    public var maxTextLength = 10_000
    /// How far before the caret to look for the previous word, in UTF-16 units.
    public var wordSearchWindow = 256
    /// Keyboard-path undo selects the replacement with one ⇧← per character; longer
    /// replacements are not undone that way.
    public var maxKeyboardUndoCharacters = 300
    public init() {}
}

public struct EngineTiming: Sendable {
    public var pollInterval = 0.01
    public var modifierReleaseTimeout = 1.5
    public var copyTimeout = 1.0
    /// How long to wait for the target app to read the pasted data. Generous on purpose: if
    /// the clipboard were restored while a stalled app still had ⌘V queued, the app would
    /// paste the user's old clipboard into the document. Normal apps read within milliseconds.
    public var pasteTimeout = 5.0
    /// After the target app has read the pasted data, wait before restoring the clipboard.
    public var pasteSettle = 0.25
    /// Pause between synthetic keystroke steps.
    public var keyStep = 0.03
    /// Some apps apply an Accessibility write a moment later; wait this long before deciding
    /// it was ignored (pasting too early would insert the text twice).
    public var axWriteSettle = 0.3
    /// After a copy timed out in a busy app, how long to wait for the late copy before
    /// restoring the clipboard (so the late copy cannot overwrite the restored contents).
    public var lateCopyGrace = 3.0
    public init() {}
}

@MainActor
public protocol Sleeping {
    func sleep(seconds: Double) async
}

public struct TaskSleeper: Sleeping {
    public init() {}
    public func sleep(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// What is needed to put the original text back. Lives only in memory and expires.
struct UndoRecord {
    let app: AppIdentity
    let element: TextElement?
    let original: String
    let replacement: String
    /// UTF-16 location of the replacement (Accessibility paths only).
    let location: Int?
    /// Spaces between the converted word and the caret (previous-word scope).
    let trailingWhitespaceUTF16: Int
    let scope: ConversionScope
    let method: WriteMethod
    let createdAt: Date
}

/// Converts the selection or the previous word in the frontmost app, and undoes it.
///
/// Safety rules applied on every request:
/// - Nothing is read in excluded apps, password fields, or while Secure Input is active.
/// - Text is replaced only after it has been read back and checked; every write is
///   verified, and when verification is impossible nothing is written.
/// - Undo restores only when the replacement is found exactly where it was put.
/// - Clipboard contents are restored afterwards unless someone changed them meanwhile.
@MainActor
public final class ConversionEngine {
    public var settings: EngineSettings
    /// Dictionary lookup that helps `auto` recognize English words (the app passes the
    /// local system spell checker). Never given anything but the single word being checked.
    public var isEnglishWord: ((String) -> Bool)?

    private let focus: FocusProviding
    private let system: SystemStateProviding
    private let pasteboard: PasteboardAccessing
    private let keys: KeystrokeSending
    private let policy: AppPolicy
    private let timing: EngineTiming
    private let sleeper: Sleeping
    private let now: () -> Date
    private let ownPID: pid_t

    private var isBusy = false
    private var undoRecord: UndoRecord?
    /// The clipboard borrowed by the request in flight, so quitting can put it back.
    private var activeTransaction: ClipboardTransaction?

    public init(
        focus: FocusProviding,
        system: SystemStateProviding,
        pasteboard: PasteboardAccessing,
        keys: KeystrokeSending,
        policy: AppPolicy = .standard,
        settings: EngineSettings = EngineSettings(),
        timing: EngineTiming = EngineTiming(),
        sleeper: Sleeping = TaskSleeper(),
        now: @escaping () -> Date = Date.init,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.focus = focus
        self.system = system
        self.pasteboard = pasteboard
        self.keys = keys
        self.policy = policy
        self.settings = settings
        self.timing = timing
        self.sleeper = sleeper
        self.now = now
        self.ownPID = ownPID
    }

    public var canUndo: Bool {
        guard let record = undoRecord else { return false }
        return now().timeIntervalSince(record.createdAt) <= settings.undoLifetime
    }

    /// Drops the undo record (original and converted text) and, if a request is in flight,
    /// puts the user's clipboard back. Called on quit.
    public func clearTemporaryData() {
        undoRecord = nil
        activeTransaction?.finish()
        activeTransaction = nil
    }

    /// Drops the undo record once it has expired. The app calls this from a one-shot timer so
    /// the text does not linger in memory after the undo window.
    public func discardExpiredUndo() {
        expireUndoIfNeeded()
    }

    // MARK: Convert

    public func convert(direction: ConversionDirection) async -> EngineOutcome {
        guard !isBusy else { return .refused(.busy) }
        isBusy = true
        defer { isBusy = false }
        expireUndoIfNeeded()

        let target: Target
        switch resolveTarget() {
        case .failure(let reason): return .refused(reason)
        case .success(let t): target = t
        }

        if let element = target.element, element.supportsSelection, policy.trustsAccessibilityText(target.app),
           let state = readState(element) {
            if state.selection.length > 0 {
                return await convertSelectionWithAX(element, state: state, app: target.app, direction: direction)
            }
            if element.canSetSelectedRange {
                return await convertPreviousWordWithAX(element, caret: state.selection.location, app: target.app, direction: direction)
            }
        }
        guard settings.allowClipboardFallback else { return .refused(.noAccessibleText) }
        return await convertWithKeyboard(app: target.app, element: target.element, direction: direction)
    }

    private struct Target {
        let app: AppIdentity
        let element: TextElement?
    }

    /// Permission, app and sensitivity checks shared by convert and undo.
    private func resolveTarget() -> Result<Target, RefusalReason> {
        guard system.isAccessibilityTrusted else { return .failure(.accessibilityPermissionDenied) }
        guard let app = focus.frontmostApp() else { return .failure(.noFrontmostApp) }
        if app.pid == ownPID { return .failure(.ownApp) }
        if policy.isExcluded(app) { return .failure(.excludedApp) }
        if system.isSecureInputActive { return .failure(.secureInputActive) }
        let lookup = focus.focusedElement(in: app)
        if case .unresponsive = lookup { return .failure(.appNotResponding) }
        let element = lookup.element
        if element?.isSecure == true { return .failure(.secureField) }
        if policy.isUnsupported(app) || element?.looksLikeTerminal == true { return .failure(.unsupportedApp) }
        return .success(Target(app: app, element: element))
    }

    /// Converts `text`, refusing text with embedded attachments: U+FFFC stands for an image
    /// or file in rich text, and writing plain text back would delete it.
    private func conversion(of text: String, direction: ConversionDirection) -> Result<ConversionResult, RefusalReason> {
        if text.contains("\u{FFFC}") { return .failure(.containsAttachment) }
        switch LayoutConverter.convert(text, direction: direction, isEnglishWord: isEnglishWord) {
        case .failure(let refusal): return .failure(RefusalReason(refusal))
        case .success(let result): return .success(result)
        }
    }

    /// True while the request's target app still owns keyboard focus and no secure input is
    /// on. Checked before every batch of synthetic keys: focus can move during the waits.
    private func stillTargeting(_ app: AppIdentity) -> Bool {
        focus.frontmostApp()?.pid == app.pid && !system.isSecureInputActive
    }

    private struct AXState {
        let selection: UTF16Range
        let selectedText: String
    }

    /// Reads the selection and cross-checks it. Returns nil when the element's answers are
    /// inconsistent, in which case its Accessibility text is not trusted at all.
    private func readState(_ element: TextElement) -> AXState? {
        do {
            let selection = try element.selectedRange()
            let count = try element.characterCount()
            guard selection.end <= count else { return nil }
            guard selection.length > 0 else { return AXState(selection: selection, selectedText: "") }
            guard selection.length <= settings.maxTextLength else { return AXState(selection: selection, selectedText: "") }
            let text = try element.string(in: selection)
            guard text.utf16.count == selection.length else { return nil }
            if let reported = try element.selectedText(), reported != text { return nil }
            return AXState(selection: selection, selectedText: text)
        } catch {
            return nil
        }
    }

    private func convertSelectionWithAX(_ element: TextElement, state: AXState, app: AppIdentity,
                                        direction: ConversionDirection) async -> EngineOutcome {
        guard state.selection.length <= settings.maxTextLength else { return .refused(.textTooLong) }
        let original = state.selectedText
        let result: ConversionResult
        switch conversion(of: original, direction: direction) {
        case .failure(let reason): return .refused(reason)
        case .success(let r): result = r
        }

        let write = await replace(in: element, range: state.selection, expected: original, with: result.text, app: app)
        guard case .success(let method) = write else { return write.outcome }

        // Leave the converted text selected so the user sees what changed (and can press
        // the shortcut again to flip it back in auto mode).
        try? element.setSelectedRange(UTF16Range(location: state.selection.location, length: result.text.utf16.count))
        undoRecord = UndoRecord(app: app, element: element, original: original, replacement: result.text,
                                location: state.selection.location, trailingWhitespaceUTF16: 0,
                                scope: .selection, method: method, createdAt: now())
        return .converted(scope: .selection, method: method, direction: result.direction)
    }

    private func convertPreviousWordWithAX(_ element: TextElement, caret: Int, app: AppIdentity,
                                           direction: ConversionDirection) async -> EngineOutcome {
        let windowStart = max(0, caret - settings.wordSearchWindow)
        let windowRange = UTF16Range(location: windowStart, length: caret - windowStart)
        guard let before = try? element.string(in: windowRange), before.utf16.count == windowRange.length else {
            return .refused(.cannotReadSafely)
        }
        guard let match = WordBoundary.lastWord(in: before) else { return .refused(.nothingToConvert) }
        // The word may continue before the window; converting half a word is not safe.
        if match.utf16Start == 0 && windowStart > 0 { return .refused(.textTooLong) }
        // Nor may it continue after the caret ("gks|rmf" would become "한|rmf").
        if match.trailingWhitespaceUTF16 == 0, let count = try? element.characterCount(), caret < count,
           let next = try? element.string(in: UTF16Range(location: caret, length: min(2, count - caret))).first,
           next.isLetter || next.isNumber {
            return .refused(.caretInsideWord)
        }

        let result: ConversionResult
        switch conversion(of: match.word, direction: direction) {
        case .failure(let reason): return .refused(reason)
        case .success(let r): result = r
        }

        let wordRange = UTF16Range(location: windowStart + match.utf16Start, length: match.utf16Length)
        let originalCaret = UTF16Range(location: caret, length: 0)

        // Select the word and confirm the app selected exactly that before writing anything.
        do {
            try element.setSelectedRange(wordRange)
            guard try element.selectedRange() == wordRange, try element.string(in: wordRange) == match.word else {
                try? element.setSelectedRange(originalCaret)
                return .refused(.cannotReadSafely)
            }
        } catch {
            try? element.setSelectedRange(originalCaret)
            return .refused(.cannotReadSafely)
        }

        let write = await replace(in: element, range: wordRange, expected: match.word, with: result.text, app: app)
        guard case .success(let method) = write else {
            if (try? element.string(in: wordRange)) == match.word { try? element.setSelectedRange(originalCaret) }
            return write.outcome
        }

        // Put the caret back where it was, shifted by the change in length.
        let newCaret = wordRange.location + result.text.utf16.count + match.trailingWhitespaceUTF16
        try? element.setSelectedRange(UTF16Range(location: newCaret, length: 0))
        undoRecord = UndoRecord(app: app, element: element, original: match.word, replacement: result.text,
                                location: wordRange.location, trailingWhitespaceUTF16: match.trailingWhitespaceUTF16,
                                scope: .previousWord, method: method, createdAt: now())
        return .converted(scope: .previousWord, method: method, direction: result.direction)
    }

    private enum WriteResult {
        case success(WriteMethod)
        case refused(RefusalReason)
        case failed(FailureReason)

        var outcome: EngineOutcome {
            switch self {
            case .success: preconditionFailure("not an error")
            case .refused(let r): return .refused(r)
            case .failed(let f): return .failed(f)
            }
        }
    }

    /// Replaces `range` (currently selected and containing `expected`) with `text`.
    /// Tries the Accessibility write first, then a clipboard paste if the app ignored it.
    private func replace(in element: TextElement, range: UTF16Range, expected: String, with text: String,
                         app: AppIdentity) async -> WriteResult {
        guard let countBefore = try? element.characterCount() else { return .failed(.accessibilityError) }
        let expectedCount = countBefore - range.length + text.utf16.count
        let replacedRange = UTF16Range(location: range.location, length: text.utf16.count)

        func isReplaced() -> Bool {
            (try? element.string(in: replacedRange)) == text && (try? element.characterCount()) == expectedCount
        }
        func isUntouched() -> Bool {
            (try? element.string(in: range)) == expected && (try? element.selectedRange()) == range
        }

        if element.canSetSelectedText {
            do {
                try element.setSelectedText(text)
            } catch TextAccessError.timedOut {
                // The app may still apply it; never paste on top of a write that may land.
                if await waitUntil(timeout: 1.0, isReplaced) { return .success(.accessibility) }
                return .failed(.accessibilityError)
            } catch {
                guard isUntouched() else { return .failed(.accessibilityError) }
            }
            // Some apps apply the write a moment later; others accept it and ignore it.
            if await waitUntil(timeout: timing.axWriteSettle, isReplaced) { return .success(.accessibility) }
            // Paste only if nothing changed at all.
            guard isUntouched() else { return .failed(.replacementNotVerified) }
        }

        guard settings.allowClipboardFallback else { return .refused(.noAccessibleText) }
        guard await waitForModifierRelease() else { return .refused(.modifiersStillHeld) }
        guard isUntouched() else { return .refused(.cannotReadSafely) }
        guard stillTargeting(app) else { return .refused(.focusChanged) }

        let transaction: ClipboardTransaction
        switch beginTransaction() {
        case .failure(let reason): return .refused(reason)
        case .success(let t): transaction = t
        }
        let pasted = await paste(text, using: transaction, into: app)
        var applied = isReplaced()
        if pasted == .confirmed, !applied {
            applied = await waitUntil(timeout: timing.pasteTimeout, isReplaced)
        }
        endTransaction(transaction)
        if applied { return .success(.accessibilityWithPaste) }
        switch pasted {
        case .focusLost: return .refused(.focusChanged)
        case .confirmed: return .failed(.replacementNotVerified)
        case .unconfirmed: return .failed(.pasteNotConfirmed)
        }
    }

    // MARK: Keyboard + clipboard path

    private func convertWithKeyboard(app: AppIdentity, element: TextElement?, direction: ConversionDirection) async -> EngineOutcome {
        guard await waitForModifierRelease() else { return .refused(.modifiersStillHeld) }
        guard stillTargeting(app) else { return .refused(.focusChanged) }
        let transaction: ClipboardTransaction
        switch beginTransaction() {
        case .failure(let reason): return .refused(reason)
        case .success(let t): transaction = t
        }

        // 1. Is something selected? ⌘C answers that without changing the document.
        switch await copySelection(transaction, from: app) {
        case .text(let selected):
            let outcome = await convertCopiedText(selected, scope: .selection, app: app, element: element,
                                                  direction: direction, transaction: transaction)
            endTransaction(transaction)
            return outcome
        case .ambiguous:
            endTransaction(transaction)
            return .refused(.cannotReadSafely)
        case .appBusy(let changeCountBefore):
            await finishAfterLateCopy(transaction, changeCountBefore: changeCountBefore)
            return .refused(.appNotResponding)
        case .focusLost:
            endTransaction(transaction)
            return .refused(.focusChanged)
        case .nothing, .emptySelectionLine:
            break
        }

        // 2. Nothing selected: select the previous word with ⌥⇧← and read it the same way.
        guard stillTargeting(app) else {
            endTransaction(transaction)
            return .refused(.focusChanged)
        }
        keys.selectWordBackward()
        await sleeper.sleep(seconds: timing.keyStep)
        let outcome: EngineOutcome
        switch await copySelection(transaction, from: app) {
        case .text(let candidate):
            if WordBoundary.singleWordWithTrailingSpace(candidate) != nil, candidate.utf16.count <= settings.wordSearchWindow {
                outcome = await convertCopiedText(candidate, scope: .previousWord, app: app, element: element,
                                                  direction: direction, transaction: transaction)
            } else {
                outcome = .refused(.cannotReadSafely)
            }
            // A selection exists (we just copied it). If nothing was pasted, collapse it to its
            // end, which is where the caret was. After a paste was sent (even unconfirmed) do
            // not: a late ⌘V followed by → would move the caret past the replacement.
            if case .refused(let reason) = outcome, reason != .focusChanged { collapse(in: app) }
        case .ambiguous:
            collapse(in: app)
            outcome = .refused(.cannotReadSafely)
        case .nothing:
            // ⌘C produced nothing in a responsive app: either ⌥⇧← selected nothing (caret at
            // the very start) or this field cannot copy. A selection left behind would be
            // deleted by the next keystroke, which is worse than nudging the caret, so collapse.
            collapse(in: app)
            outcome = .refused(.cannotReadSafely)
        case .emptySelectionLine:
            // The editor told us the selection is empty: ⌥⇧← selected nothing, so → would move.
            outcome = .refused(.cannotReadSafely)
        case .appBusy(let changeCountBefore):
            // Keys are processed in order, so a queued → collapses the queued ⌥⇧← selection.
            collapse(in: app)
            await finishAfterLateCopy(transaction, changeCountBefore: changeCountBefore)
            return .refused(.appNotResponding)
        case .focusLost:
            outcome = .refused(.focusChanged)
        }
        endTransaction(transaction)
        return outcome
    }

    private func collapse(in app: AppIdentity) {
        if stillTargeting(app) { keys.collapseSelectionToEnd() }
    }

    private func convertCopiedText(_ text: String, scope: ConversionScope, app: AppIdentity, element: TextElement?,
                                   direction: ConversionDirection, transaction: ClipboardTransaction) async -> EngineOutcome {
        guard text.utf16.count <= settings.maxTextLength else { return .refused(.textTooLong) }
        let result: ConversionResult
        switch conversion(of: text, direction: direction) {
        case .failure(let reason): return .refused(reason)
        case .success(let r): result = r
        }
        switch await paste(result.text, using: transaction, into: app) {
        case .focusLost: return .refused(.focusChanged)
        case .unconfirmed: return .failed(.pasteNotConfirmed)
        case .confirmed: break
        }
        // The focused element (if Accessibility reports one) pins undo to this field even
        // though its text could not be used.
        undoRecord = UndoRecord(app: app, element: element, original: text, replacement: result.text, location: nil,
                                trailingWhitespaceUTF16: 0, scope: scope, method: .keyboard, createdAt: now())
        return .converted(scope: scope, method: .keyboard, direction: result.direction)
    }

    private enum CopyResult: Equatable {
        case text(String)
        /// Something was copied but it may not be a real selection.
        case ambiguous
        /// Nothing was copied and the app is responsive, so nothing is coming.
        case nothing
        /// The editor reported an empty selection (VS Code copies the line then).
        case emptySelectionLine
        /// Nothing was copied yet because the app is not processing events.
        case appBusy(changeCountBefore: Int)
        case focusLost
    }

    private func copySelection(_ transaction: ClipboardTransaction, from app: AppIdentity) async -> CopyResult {
        guard stillTargeting(app) else { return .focusLost }
        let before = pasteboard.changeCount
        keys.copy()
        let changed = await waitUntil(timeout: timing.copyTimeout) { self.pasteboard.changeCount != before }
        guard changed else {
            // An app that answers Accessibility has processed the ⌘C queued before it, so no
            // copy is coming. One that does not may still copy later.
            return focus.isResponsive(app) ? .nothing : .appBusy(changeCountBefore: before)
        }
        transaction.acceptCurrentChange()
        guard let text = pasteboard.readString(), !text.isEmpty else { return .nothing }
        if isEmptySelectionLineCopy() { return .emptySelectionLine }
        // Editors like JetBrains IDEs and Sublime Text copy the whole current line when nothing
        // is selected. Pasting over that would insert instead of replace, so a copied single
        // line ending in a line break is not trusted as a selection.
        if text.last?.isNewline == true, text.dropLast().allSatisfy({ !$0.isNewline }) { return .ambiguous }
        return .text(text)
    }

    /// A busy app may still perform the ⌘C we sent. Wait for it before restoring, so the late
    /// copy cannot replace the restored clipboard with document text.
    private func finishAfterLateCopy(_ transaction: ClipboardTransaction, changeCountBefore: Int) async {
        if await waitUntil(timeout: timing.lateCopyGrace, { self.pasteboard.changeCount != changeCountBefore }) {
            transaction.acceptCurrentChange()
        }
        endTransaction(transaction)
    }

    /// VS Code and other Monaco editors mark line copies made with an empty selection.
    private func isEmptySelectionLineCopy() -> Bool {
        guard let data = pasteboard.data(forType: "vscode-editor-data"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["isFromEmptySelection"] as? Bool == true
    }

    private enum PasteOutcome { case confirmed, unconfirmed, focusLost }

    /// Puts `text` on the clipboard, sends ⌘V, and waits until the target app has read it.
    private func paste(_ text: String, using transaction: ClipboardTransaction, into app: AppIdentity) async -> PasteOutcome {
        guard stillTargeting(app) else { return .focusLost }
        let handle = transaction.write(text)
        keys.paste()
        let read = await waitUntil(timeout: timing.pasteTimeout) { handle.wasRead }
        // Give the app a moment to finish inserting before the clipboard changes back.
        await sleeper.sleep(seconds: timing.pasteSettle)
        return read ? .confirmed : .unconfirmed
    }

    // MARK: Undo

    public func undo() async -> EngineOutcome {
        guard !isBusy else { return .refused(.busy) }
        isBusy = true
        defer { isBusy = false }
        expireUndoIfNeeded()
        guard let record = undoRecord else { return .refused(.undoUnavailable) }

        let target: Target
        switch resolveTarget() {
        case .failure(let reason): return .refused(reason)
        case .success(let t): target = t
        }
        guard target.app.pid == record.app.pid else { return .refused(.undoTargetChanged) }

        let outcome: EngineOutcome
        switch record.method {
        case .accessibility, .accessibilityWithPaste:
            outcome = await undoWithAX(record, element: target.element, app: target.app)
        case .keyboard:
            outcome = await undoWithKeyboard(record, element: target.element, app: target.app)
        }
        // A refused undo, or a paste the app never took, leaves the record so the user can
        // retry; after a success or a failed write it is gone.
        switch outcome {
        case .refused, .failed(.pasteNotConfirmed): break
        default: undoRecord = nil
        }
        return outcome
    }

    private func undoWithAX(_ record: UndoRecord, element: TextElement?, app: AppIdentity) async -> EngineOutcome {
        guard let element, let recorded = record.element, element.isSameElement(as: recorded),
              element.canSetSelectedRange, let location = record.location else {
            return .refused(.undoTargetChanged)
        }
        let range = UTF16Range(location: location, length: record.replacement.utf16.count)
        guard (try? element.string(in: range)) == record.replacement else { return .refused(.undoTargetChanged) }
        let selectionBefore = try? element.selectedRange()
        do {
            try element.setSelectedRange(range)
            guard try element.selectedRange() == range else { return .refused(.undoTargetChanged) }
        } catch {
            return .refused(.undoTargetChanged)
        }

        let write = await replace(in: element, range: range, expected: record.replacement, with: record.original, app: app)
        guard case .success(let method) = write else {
            // Nothing was written: give the user their selection back instead of leaving the
            // replacement selected for the next keystroke to delete.
            if let selectionBefore, (try? element.string(in: range)) == record.replacement {
                try? element.setSelectedRange(selectionBefore)
            }
            return write.outcome
        }

        let originalLength = record.original.utf16.count
        if record.scope == .selection, selectionBefore == range || selectionBefore == nil {
            // Untouched since the conversion: select the original again.
            try? element.setSelectedRange(UTF16Range(location: location, length: originalLength))
        } else if let before = selectionBefore {
            // Keep the user's caret/selection where it was, shifted by the length change.
            let delta = originalLength - range.length
            let mapped: UTF16Range
            if before.location >= range.end {
                mapped = UTF16Range(location: before.location + delta, length: before.length)
            } else if before.end <= range.location {
                mapped = before
            } else {
                mapped = UTF16Range(location: location + originalLength, length: 0)
            }
            try? element.setSelectedRange(mapped)
        } else {
            try? element.setSelectedRange(UTF16Range(location: location + originalLength + record.trailingWhitespaceUTF16, length: 0))
        }
        return .undone(method: method)
    }

    private func undoWithKeyboard(_ record: UndoRecord, element: TextElement?, app: AppIdentity) async -> EngineOutcome {
        guard settings.allowClipboardFallback else { return .refused(.noAccessibleText) }
        // Same app is not enough: another field of it may end with the same text.
        if let recorded = record.element {
            guard let element, element.isSameElement(as: recorded) else { return .refused(.undoTargetChanged) }
        }
        guard record.replacement.count <= settings.maxKeyboardUndoCharacters else { return .refused(.textTooLong) }
        guard await waitForModifierRelease() else { return .refused(.modifiersStillHeld) }
        guard stillTargeting(app) else { return .refused(.focusChanged) }
        let transaction: ClipboardTransaction
        switch beginTransaction() {
        case .failure(let reason): return .refused(reason)
        case .success(let t): transaction = t
        }

        // The caret should sit right after the replacement. Select that many characters
        // backwards and check they are exactly the replacement before touching anything.
        keys.extendSelectionBackward(characters: record.replacement.count)
        await sleeper.sleep(seconds: timing.keyStep)
        let copied = await copySelection(transaction, from: app)
        guard case .text(let selected) = copied, normalized(selected) == normalized(record.replacement) else {
            switch copied {
            case .appBusy(let before):
                collapse(in: app)
                await finishAfterLateCopy(transaction, changeCountBefore: before)
                return .refused(.appNotResponding)
            case .focusLost:
                endTransaction(transaction)
                return .refused(.focusChanged)
            case .emptySelectionLine:
                break
            default:
                collapse(in: app)
            }
            endTransaction(transaction)
            return .refused(.undoTargetChanged)
        }

        let pasted = await paste(record.original, using: transaction, into: app)
        if pasted == .confirmed, record.scope == .selection, record.original.count <= settings.maxKeyboardUndoCharacters,
           stillTargeting(app) {
            keys.extendSelectionBackward(characters: record.original.count)
        }
        endTransaction(transaction)
        switch pasted {
        case .confirmed: return .undone(method: .keyboard)
        case .unconfirmed: return .failed(.pasteNotConfirmed)
        case .focusLost: return .refused(.focusChanged)
        }
    }

    // MARK: Helpers

    private func beginTransaction() -> Result<ClipboardTransaction, RefusalReason> {
        do {
            let transaction = try ClipboardTransaction(pasteboard: pasteboard)
            activeTransaction = transaction
            return .success(transaction)
        } catch {
            return .failure(RefusalReason(error))
        }
    }

    private func endTransaction(_ transaction: ClipboardTransaction) {
        transaction.finish()
        if activeTransaction === transaction { activeTransaction = nil }
    }

    private func expireUndoIfNeeded() {
        if undoRecord != nil, !canUndo { undoRecord = nil }
    }

    private func normalized(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    private func waitForModifierRelease() async -> Bool {
        await waitUntil(timeout: timing.modifierReleaseTimeout) { self.keys.modifiersReleased() }
    }

    /// Polls `condition` for at most `timeout` seconds. Used only while a request is in
    /// flight (a few hundred milliseconds at most), never while idle.
    private func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        if condition() { return true }
        var waited = 0.0
        while waited < timeout {
            await sleeper.sleep(seconds: timing.pollInterval)
            waited += timing.pollInterval
            if condition() { return true }
        }
        return false
    }
}
