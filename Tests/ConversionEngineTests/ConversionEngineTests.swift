import Foundation
import Testing
import AccessibilityText
import ClipboardBridge
import HangulLayout
@testable import ConversionEngine

@MainActor
@Suite("Accessibility path")
struct AccessibilityPathTests {
    @Test("Selected text is replaced and the result stays selected")
    func selection() async {
        let h = Harness("hello [dkssud] world")
        let outcome = await h.engine.convert(direction: .englishToKorean)
        #expect(outcome == .converted(scope: .selection, method: .accessibility, direction: .englishToKorean))
        #expect(h.doc.marked == "hello [안녕] world")
        #expect(h.pasteboard.changeCount == 1, "clipboard must not be touched on the AX path")
    }

    @Test("Previous word before the caret is replaced; caret is restored", arguments: [
        ("gksrmf|", "한글|"),
        ("dkssudgktpdy|", "안녕하세요|"),
        ("foo gksrmf  |", "foo 한글  |"),
        ("dkssud| world", "안녕| world"),
        ("line one\ngksrmf|", "line one\n한글|"),
        ("😀 dkssud|", "😀 안녕|"),
        ("dkssud, |", "안녕, |"),
    ])
    func previousWord(input: String, expected: String) async {
        let h = Harness(input)
        let outcome = await h.engine.convert(direction: .auto)
        #expect(outcome.isSuccess)
        #expect(h.doc.marked == expected)
    }

    @Test("Korean back to English keystrokes")
    func koreanToEnglish() async {
        let h = Harness("인사: 안녕|")
        #expect(await h.engine.convert(direction: .koreanToEnglish).isSuccess)
        #expect(h.doc.marked == "인사: dkssud|")
    }

    @Test("No word before the caret: nothing is changed", arguments: ["|", "abc\n|", "   |", "abc\n  |"])
    func noWord(input: String) async {
        let h = Harness(input)
        #expect(await h.engine.convert(direction: .auto) == .refused(.nothingToConvert))
        #expect(h.doc.marked == input)
        #expect(h.element.writeCount == 0)
    }

    @Test("A word longer than the search window is not cut in half")
    func wordTooLong() async {
        var settings = EngineSettings()
        settings.wordSearchWindow = 8
        let h = Harness("dkssudgktpdy|", settings: settings)
        #expect(await h.engine.convert(direction: .englishToKorean) == .refused(.textTooLong))
        #expect(h.doc.marked == "dkssudgktpdy|")
    }

    @Test("Result identical to the original: nothing is written")
    func unchanged() async {
        let h = Harness("total [123 !?]")
        #expect(await h.engine.convert(direction: .auto) == .refused(.unchanged))
        #expect(h.element.writeCount == 0)
        #expect(h.doc.marked == "total [123 !?]")
    }

    @Test("Explicit direction protects valid English text in auto mode")
    func explicitDirection() async {
        let auto = Harness("say hello|")
        #expect(await auto.engine.convert(direction: .auto) == .refused(.looksLikeEnglish))
        #expect(auto.doc.marked == "say hello|")

        let wrongWay = Harness("say hello|")
        #expect(await wrongWay.engine.convert(direction: .koreanToEnglish) == .refused(.unchanged))
        #expect(wrongWay.doc.marked == "say hello|")

        let explicit = Harness("say hello|")
        #expect(await explicit.engine.convert(direction: .englishToKorean).isSuccess)
        #expect(explicit.doc.marked == "say ㅗ디ㅣㅐ|")
    }

    @Test("Mixed selection in auto mode is refused")
    func mixed() async {
        let h = Harness("[안녕 dkssud]")
        #expect(await h.engine.convert(direction: .auto) == .refused(.mixedScripts))
        #expect(h.element.writeCount == 0)
    }

    @Test("App ignores the AX write → clipboard paste, then clipboard restored")
    func ignoredWriteFallsBackToPaste() async throws {
        let h = Harness("[gksrmf]")
        h.element.ignoresTextWrites = true
        let before = try h.pasteboard.snapshot()
        let outcome = await h.engine.convert(direction: .auto)
        #expect(outcome == .converted(scope: .selection, method: .accessibilityWithPaste, direction: .englishToKorean))
        #expect(h.doc.text == "한글")
        #expect(try h.pasteboard.snapshot() == before)
    }

    @Test("Paste not accepted either → failure reported, text and clipboard intact")
    func pasteIgnored() async throws {
        let h = Harness("[gksrmf]")
        h.element.ignoresTextWrites = true
        h.keyboard.supportsPaste = false
        let before = try h.pasteboard.snapshot()
        #expect(await h.engine.convert(direction: .auto) == .failed(.pasteNotConfirmed))
        #expect(h.doc.marked == "[gksrmf]")
        #expect(try h.pasteboard.snapshot() == before)
    }

    @Test("Inconsistent Accessibility answers are not trusted (keyboard path used)")
    func inconsistentAX() async {
        let h = Harness("[gksrmf]")
        h.element.reportsWrongSelectedText = true
        let outcome = await h.engine.convert(direction: .auto)
        #expect(outcome == .converted(scope: .selection, method: .keyboard, direction: .englishToKorean))
        #expect(h.element.writeCount == 0)
        #expect(h.doc.text == "한글")
    }

    @Test("Electron apps use the keyboard path even when AX answers")
    func electron() async throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Fake-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let app = AppIdentity(pid: 2002, bundleIdentifier: "com.microsoft.VSCode", name: "Code", bundleURL: bundle)
        let h = Harness("foo dkssud|", app: app)
        let outcome = await h.engine.convert(direction: .auto)
        #expect(outcome == .converted(scope: .previousWord, method: .keyboard, direction: .englishToKorean))
        #expect(h.element.writeCount == 0)
        #expect(h.doc.marked == "foo 안녕|")
    }
}

@MainActor
@Suite("Undo")
struct UndoTests {
    @Test("Undo restores a converted word and the original caret position")
    func undoPreviousWord() async {
        let h = Harness("foo gksrmf  |")
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        #expect(h.engine.canUndo)
        #expect(await h.engine.undo() == .undone(method: .accessibility))
        #expect(h.doc.marked == "foo gksrmf  |")
        #expect(!h.engine.canUndo)
    }

    @Test("Undo restores a converted selection and selects the original again")
    func undoSelection() async {
        let h = Harness("a [dkssud] b")
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        #expect(await h.engine.undo().isSuccess)
        #expect(h.doc.marked == "a [dkssud] b")
    }

    @Test("Undo after Korean → English (replacement longer than original)")
    func undoLengthChange() async {
        let h = Harness("x 안녕하세요| y")
        #expect(await h.engine.convert(direction: .koreanToEnglish).isSuccess)
        #expect(h.doc.marked == "x dkssudgktpdy| y")
        #expect(await h.engine.undo().isSuccess)
        #expect(h.doc.marked == "x 안녕하세요| y")
    }

    @Test("Undo is skipped when the text was edited since the conversion")
    func undoAfterEdit() async {
        let h = Harness("gksrmf|")
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        h.doc.text = "한x글"
        #expect(await h.engine.undo() == .refused(.undoTargetChanged))
        #expect(h.doc.text == "한x글")
    }

    @Test("Undo is skipped in another app or another field")
    func undoElsewhere() async {
        let h = Harness("gksrmf|")
        #expect(await h.engine.convert(direction: .auto).isSuccess)

        h.focus.app = AppIdentity(pid: 3003, bundleIdentifier: "com.apple.Safari", name: "Safari")
        #expect(await h.engine.undo() == .refused(.undoTargetChanged))

        h.focus.app = Harness.notes
        let otherField = FakeTextElement(FakeDocument("한글"))
        h.focus.element = otherField
        #expect(await h.engine.undo() == .refused(.undoTargetChanged))
        #expect(otherField.doc.text == "한글")

        // Back in the original field it still works.
        h.focus.element = h.element
        #expect(await h.engine.undo().isSuccess)
        #expect(h.doc.text == "gksrmf")
    }

    @Test("Undo data expires")
    func undoExpires() async {
        let h = Harness("gksrmf|")
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        h.clock.now += 121
        #expect(!h.engine.canUndo)
        #expect(await h.engine.undo() == .refused(.undoUnavailable))
        #expect(h.doc.text == "한글")
    }

    @Test("clearTemporaryData drops the undo record")
    func clearData() async {
        let h = Harness("gksrmf|")
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        h.engine.clearTemporaryData()
        #expect(await h.engine.undo() == .refused(.undoUnavailable))
    }
}

@MainActor
@Suite("Keyboard + clipboard path")
struct KeyboardPathTests {
    @Test("Selected text via ⌘C/⌘V; clipboard restored")
    func selection() async throws {
        let h = Harness("hello [dkssud]", accessibility: false)
        let before = try h.pasteboard.snapshot()
        let outcome = await h.engine.convert(direction: .auto)
        #expect(outcome == .converted(scope: .selection, method: .keyboard, direction: .englishToKorean))
        #expect(h.doc.text == "hello 안녕")
        #expect(try h.pasteboard.snapshot() == before)
    }

    @Test("Previous word via ⌥⇧←; clipboard restored, caret where it was")
    func previousWord() async throws {
        let h = Harness("foo dkssud|", accessibility: false)
        let before = try h.pasteboard.snapshot()
        #expect(await h.engine.convert(direction: .auto) == .converted(scope: .previousWord, method: .keyboard, direction: .englishToKorean))
        #expect(h.doc.marked == "foo 안녕|")
        #expect(try h.pasteboard.snapshot() == before)
        #expect(h.keyboard.log == ["copy", "selectWordBackward", "copy", "paste"])
    }

    @Test("Empty clipboard stays empty afterwards")
    func emptyClipboard() async throws {
        let h = Harness("dkssud|", accessibility: false, clipboard: nil)
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        #expect(try h.pasteboard.snapshot().isEmpty)
    }

    @Test("User copies something during the operation → their new clipboard is kept")
    func newerClipboardKept() async {
        let h = Harness("[dkssud]", accessibility: false)
        h.sleeper.onSleep = { [pasteboard = h.pasteboard, keyboard = h.keyboard] _ in
            // Right after our paste, the user copies something else.
            if keyboard.log.last == "paste", pasteboard.readString() != "user's new copy" {
                pasteboard.setUserString("user's new copy")
            }
        }
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        #expect(h.pasteboard.readString() == "user's new copy")
    }

    @Test("⌘C not supported → nothing changed; the ⌥⇧← selection is collapsed back")
    func copyUnsupported() async {
        let h = Harness("foo dkssud|", accessibility: false)
        h.keyboard.supportsCopy = false
        #expect(await h.engine.convert(direction: .auto) == .refused(.cannotReadSafely))
        #expect(h.doc.marked == "foo dkssud|", "no stray selection for the next keystroke to delete")
        #expect(!h.keyboard.log.contains("paste"))
        #expect(h.pasteboard.readString() == "user clipboard")
    }

    @Test("VS Code style line copy on empty selection is recognized and ignored")
    func vscodeLineCopy() async {
        let h = Harness("foo dkssud|", accessibility: false)
        h.keyboard.emptySelectionCopy = .lineWithVSCodeMarker
        #expect(await h.engine.convert(direction: .auto) == .converted(scope: .previousWord, method: .keyboard, direction: .englishToKorean))
        #expect(h.doc.marked == "foo 안녕|")
        #expect(h.pasteboard.readString() == "user clipboard")
    }

    @Test("Unmarked whole-line copy (JetBrains style) is treated as unsafe")
    func unmarkedLineCopy() async {
        let h = Harness("foo dkssud|", accessibility: false)
        h.keyboard.emptySelectionCopy = .lineWithoutMarker
        #expect(await h.engine.convert(direction: .auto) == .refused(.cannotReadSafely))
        #expect(h.doc.marked == "foo dkssud|")
        #expect(h.pasteboard.readString() == "user clipboard")
    }

    @Test("⌥⇧← grabbing a line break is rejected and the selection collapsed back")
    func wordAcrossLines() async {
        let h = Harness("dkssud\n|", accessibility: false)
        #expect(await h.engine.convert(direction: .auto) == .refused(.cannotReadSafely))
        #expect(h.doc.marked == "dkssud\n|")
    }

    @Test("Unconvertible previous word: selection collapsed back to the caret")
    func previousWordUnchanged() async {
        let h = Harness("total 123|", accessibility: false)
        #expect(await h.engine.convert(direction: .auto) == .refused(.unchanged))
        #expect(h.doc.marked == "total 123|")
    }

    @Test("Keyboard undo restores the word after verifying it")
    func undo() async throws {
        let h = Harness("foo dkssud|", accessibility: false)
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        let before = try h.pasteboard.snapshot()
        #expect(await h.engine.undo() == .undone(method: .keyboard))
        #expect(h.doc.marked == "foo dkssud|")
        #expect(try h.pasteboard.snapshot() == before)
    }

    @Test("Keyboard undo of a selection re-selects the original")
    func undoSelection() async {
        let h = Harness("x [gksrmf]", accessibility: false)
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        #expect(await h.engine.undo().isSuccess)
        #expect(h.doc.marked == "x [gksrmf]")
    }

    @Test("Keyboard undo refuses when text after the conversion changed")
    func undoAfterTyping() async {
        let h = Harness("foo dkssud|", accessibility: false)
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        h.doc.replaceSelection(with: "!") // user typed after converting
        #expect(await h.engine.undo() == .refused(.undoTargetChanged))
        #expect(h.doc.marked == "foo 안녕!|")
    }

    @Test("Shortcut modifiers still held → no synthetic keys are sent")
    func modifiersHeld() async {
        let h = Harness("[dkssud]", accessibility: false)
        h.keyboard.modifiersHeldForPolls = 10_000
        #expect(await h.engine.convert(direction: .auto) == .refused(.modifiersStillHeld))
        #expect(h.keyboard.log.isEmpty)
    }

    @Test("Waits for the user to release the shortcut, then proceeds")
    func modifiersReleasedLater() async {
        let h = Harness("[dkssud]", accessibility: false)
        h.keyboard.modifiersHeldForPolls = 20
        #expect(await h.engine.convert(direction: .auto).isSuccess)
    }

    @Test("Clipboard fallback disabled → refused without sending keys")
    func fallbackDisabled() async {
        var settings = EngineSettings()
        settings.allowClipboardFallback = false
        let h = Harness("[dkssud]", accessibility: false, settings: settings)
        #expect(await h.engine.convert(direction: .auto) == .refused(.noAccessibleText))
        #expect(h.keyboard.log.isEmpty)
    }
}

@MainActor
@Suite("Permissions, sensitive fields and unsupported apps")
struct SafetyTests {
    @Test("Accessibility permission denied → nothing read, no keys, clipboard untouched")
    func permissionDenied() async {
        let h = Harness("[dkssud]")
        h.system.isAccessibilityTrusted = false
        #expect(await h.engine.convert(direction: .auto) == .refused(.accessibilityPermissionDenied))
        #expect(await h.engine.undo() == .refused(.undoUnavailable))
        #expect(h.element.readCount == 0)
        #expect(h.keyboard.log.isEmpty)
        #expect(h.pasteboard.changeCount == 1)
    }

    @Test("Password field → refused before any text is read")
    func secureField() async {
        let h = Harness("[dkssud]")
        h.element.isSecure = true
        #expect(await h.engine.convert(direction: .auto) == .refused(.secureField))
        #expect(h.element.readCount == 0)
        #expect(h.keyboard.log.isEmpty)
    }

    @Test("Secure Event Input active → refused, even without Accessibility text")
    func secureInput() async {
        let h = Harness("[dkssud]", accessibility: false)
        h.system.isSecureInputActive = true
        #expect(await h.engine.convert(direction: .auto) == .refused(.secureInputActive))
        #expect(h.keyboard.log.isEmpty)
    }

    @Test("Excluded apps (password managers) are never read")
    func excludedApp() async {
        let app = AppIdentity(pid: 4004, bundleIdentifier: "com.1password.1password", name: "1Password")
        let h = Harness("[dkssud]", app: app)
        #expect(await h.engine.convert(direction: .auto) == .refused(.excludedApp))
        #expect(h.element.readCount == 0)
    }

    @Test("Terminals are unsupported")
    func terminal() async {
        let app = AppIdentity(pid: 5005, bundleIdentifier: "com.apple.Terminal", name: "Terminal")
        let h = Harness("dkssud|", accessibility: false, app: app)
        #expect(await h.engine.convert(direction: .auto) == .refused(.unsupportedApp))
        #expect(h.keyboard.log.isEmpty)
    }

    @Test("Hotkey pressed while LayoutFix itself is frontmost is ignored")
    func ownApp() async {
        let app = AppIdentity(pid: 99, bundleIdentifier: "dev.layoutfix.LayoutFix", name: "LayoutFix")
        let h = Harness("[dkssud]", app: app)
        #expect(await h.engine.convert(direction: .auto) == .refused(.ownApp))
    }

    @Test("No frontmost app")
    func noApp() async {
        let h = Harness("[dkssud]")
        h.focus.app = nil
        #expect(await h.engine.convert(direction: .auto) == .refused(.noFrontmostApp))
    }

    @Test("A second request while one is running is refused")
    func busy() async {
        let h = Harness("[dkssud]", accessibility: false)
        h.keyboard.modifiersHeldForPolls = 5
        async let first = h.engine.convert(direction: .auto)
        // Wait until the first request is inside the engine (it has started polling the modifiers).
        for _ in 0..<1000 where h.keyboard.modifiersHeldForPolls == 5 { await Task.yield() }
        let second = await h.engine.convert(direction: .auto)
        #expect(second == .refused(.busy))
        #expect(await first.isSuccess)
        #expect(h.doc.text == "안녕")
    }

    @Test("Status messages never contain the converted text")
    func messagesHaveNoUserText() async {
        let h = Harness("[dkssudgktpdy]")
        let outcome = await h.engine.convert(direction: .auto)
        #expect(!outcome.message.contains("dkssud"))
        #expect(!outcome.message.contains("안녕"))
    }
}

@Suite("Word boundaries")
struct WordBoundaryTests {
    @Test func basics() {
        #expect(WordBoundary.lastWord(in: "foo bar")?.word == "bar")
        #expect(WordBoundary.lastWord(in: "foo bar  ")?.trailingWhitespaceUTF16 == 2)
        #expect(WordBoundary.lastWord(in: "foo\nbar")?.utf16Start == 4)
        #expect(WordBoundary.lastWord(in: "foo\n") == nil)
        #expect(WordBoundary.lastWord(in: "") == nil)
        #expect(WordBoundary.lastWord(in: "😀 ab")?.utf16Start == 3)
    }
}

@MainActor
@Suite("Review regressions")
struct ReviewRegressionTests {
    @Test("Unresponsive app: refused before any key is sent or clipboard touched")
    func unresponsiveApp() async {
        let h = Harness("foo dkssud|", accessibility: false)
        h.focus.unresponsive = true
        #expect(await h.engine.convert(direction: .auto) == .refused(.appNotResponding))
        #expect(h.keyboard.log.isEmpty)
        #expect(h.pasteboard.writesByEngine == 0)
    }

    @Test("Clipboard that cannot be saved completely is never overwritten", arguments: [
        ClipboardUnavailable.unreadable, .accessDenied, .tooLarge,
    ])
    func unsavableClipboard(failure: ClipboardUnavailable) async {
        let h = Harness("hello [dkssud]", accessibility: false)
        h.pasteboard.snapshotFailure = failure
        let outcome = await h.engine.convert(direction: .auto)
        #expect(!outcome.isSuccess)
        #expect(h.keyboard.log.isEmpty, "no ⌘C may run when the clipboard could not be saved")
        #expect(h.pasteboard.writesByEngine == 0)
        #expect(h.pasteboard.readString() == "user clipboard")
        #expect(h.doc.marked == "hello [dkssud]")
    }

    @Test("Concealed clipboard (password manager) is left alone")
    func concealedClipboard() async {
        let h = Harness("hello [dkssud]", accessibility: false, clipboard: nil)
        h.pasteboard.setUserString("hunter2", extraTypes: [PasteboardMarkers.concealed: Data()])
        #expect(await h.engine.convert(direction: .auto) == .refused(.clipboardHoldsSensitiveData))
        #expect(h.pasteboard.writesByEngine == 0)
        #expect(h.keyboard.log.isEmpty)
    }

    @Test("AX path needing a paste also refuses when the clipboard cannot be saved")
    func axPasteWithUnsavableClipboard() async {
        let h = Harness("[gksrmf]")
        h.element.ignoresTextWrites = true
        h.pasteboard.snapshotFailure = .unreadable
        #expect(await h.engine.convert(direction: .auto) == .refused(.clipboardNotPreservable))
        #expect(h.doc.marked == "[gksrmf]")
        #expect(h.pasteboard.writesByEngine == 0)
    }

    @Test("Stalled app: no restore while ⌘V may still be queued; no stray → afterwards")
    func stalledPaste() async {
        let h = Harness("foo dkssud|", accessibility: false)
        h.keyboard.stalledPaste = true
        var sleepsAfterPaste = 0
        h.sleeper.onSleep = { [keyboard = h.keyboard] _ in
            guard keyboard.log.last == "paste" else { return }
            sleepsAfterPaste += 1
            // The app wakes up 2 s after ⌘V (polls are 10 ms): later than the old 1 s timeout.
            if sleepsAfterPaste == 200 { keyboard.deliverQueuedPaste() }
        }
        let outcome = await h.engine.convert(direction: .auto)
        #expect(outcome == .converted(scope: .previousWord, method: .keyboard, direction: .englishToKorean))
        #expect(h.doc.marked == "foo 안녕|", "the late paste must insert the conversion, not the old clipboard")
        #expect(h.pasteboard.readString() == "user clipboard")
        #expect(!h.keyboard.log.contains("collapse"))
    }

    @Test("Paste never read: failure, clipboard restored, caret not moved by →")
    func pasteNeverRead() async {
        let h = Harness("foo dkssud|", accessibility: false)
        h.keyboard.stalledPaste = true // never delivered
        #expect(await h.engine.convert(direction: .auto) == .failed(.pasteNotConfirmed))
        #expect(h.pasteboard.readString() == "user clipboard")
        #expect(!h.keyboard.log.contains("collapse"))
    }

    @Test("Keyboard undo refuses in a different field of the same app")
    func keyboardUndoOtherField() async {
        let h = Harness("foo dkssud|", accessibility: false)
        // The app reports a focused element (identity only; its text is not trusted).
        let fieldA = FakeTextElement(FakeDocument(""))
        fieldA.supportsSelection = false
        h.focus.element = fieldA
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        let fieldB = FakeTextElement(FakeDocument(""))
        fieldB.supportsSelection = false
        h.focus.element = fieldB
        #expect(await h.engine.undo() == .refused(.undoTargetChanged))
        #expect(h.doc.marked == "foo 안녕|")
        h.focus.element = fieldA
        #expect(await h.engine.undo().isSuccess)
        #expect(h.doc.marked == "foo dkssud|")
    }

    @Test("Quitting mid-operation puts the user's clipboard back")
    func quitDuringOperation() async {
        let h = Harness("foo dkssud|", accessibility: false)
        h.keyboard.stalledPaste = true
        var cleared = false
        h.sleeper.onSleep = { [engine = h.engine, keyboard = h.keyboard] _ in
            if keyboard.log.last == "paste", !cleared {
                cleared = true
                engine.clearTemporaryData() // what applicationWillTerminate does
            }
        }
        _ = await h.engine.convert(direction: .auto)
        #expect(cleared)
        #expect(h.pasteboard.readString() == "user clipboard")
    }

    @Test("Expired undo text can be discarded without a hotkey press")
    func discardExpired() async {
        let h = Harness("gksrmf|")
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        h.engine.discardExpiredUndo()
        #expect(h.engine.canUndo)
        h.clock.now += 121
        h.engine.discardExpiredUndo()
        #expect(!h.engine.canUndo)
    }

    // MARK: Engine review (E1–E15)

    @Test("E1: focus moves to another app during the wait → no keys reach it")
    func focusMovesDuringWait() async {
        let h = Harness("foo dkssud|", accessibility: false)
        h.keyboard.modifiersHeldForPolls = 5
        let onePassword = AppIdentity(pid: 4004, bundleIdentifier: "com.1password.1password", name: "1Password")
        h.sleeper.onSleep = { [focus = h.focus] count in if count == 2 { focus.app = onePassword } }
        #expect(await h.engine.convert(direction: .auto) == .refused(.focusChanged))
        #expect(h.keyboard.log.isEmpty)
        #expect(h.pasteboard.writesByEngine == 0)
    }

    @Test("E1: focus moves after ⌥⇧← → no paste into the other app")
    func focusMovesBeforePaste() async {
        let h = Harness("foo dkssud|", accessibility: false)
        let other = AppIdentity(pid: 5005, bundleIdentifier: "com.example.Other", name: "Other")
        h.sleeper.onSleep = { [focus = h.focus, keyboard = h.keyboard] _ in
            if keyboard.log.last == "selectWordBackward" { focus.app = other }
        }
        #expect(await h.engine.convert(direction: .auto) == .refused(.focusChanged))
        #expect(!h.keyboard.log.contains("paste"))
        #expect(h.doc.text == "foo dkssud")
        #expect(h.pasteboard.readString() == "user clipboard")
    }

    @Test("E2: text with an attachment (U+FFFC) is refused", arguments: ["see gksrmf\u{FFFC}|", "[gksrmf\u{FFFC}]"])
    func attachments(input: String) async {
        let h = Harness(input)
        #expect(await h.engine.convert(direction: .englishToKorean) == .refused(.containsAttachment))
        #expect(h.element.writeCount == 0)
    }

    @Test("E4: busy app with a selection → refused, late copy absorbed, clipboard restored, no ⌥⇧←")
    func busyAppWithSelection() async {
        let h = Harness("foo [dkssud]", accessibility: false)
        h.keyboard.busyForPolls = 150 // 1.5 s, longer than the 1 s copy timeout
        #expect(await h.engine.convert(direction: .auto) == .refused(.appNotResponding))
        #expect(h.doc.marked == "foo [dkssud]")
        #expect(!h.keyboard.log.contains("selectWordBackward"))
        #expect(h.pasteboard.readString() == "user clipboard", "the late ⌘C must not replace the restored clipboard")
    }

    @Test("E4: busy app without a selection → refused, clipboard intact")
    func busyAppNoSelection() async {
        let h = Harness("foo dkssud|", accessibility: false)
        h.keyboard.busyForPolls = 150
        #expect(await h.engine.convert(direction: .auto) == .refused(.appNotResponding))
        #expect(h.doc.marked == "foo dkssud|")
        #expect(h.pasteboard.readString() == "user clipboard")
    }

    @Test("E6: AX write applied a moment later is not pasted a second time")
    func delayedAXWrite() async {
        let h = Harness("[gksrmf]")
        h.element.appliesWritesAfterPolls = 5
        #expect(await h.engine.convert(direction: .auto) == .converted(scope: .selection, method: .accessibility, direction: .englishToKorean))
        #expect(h.doc.text == "한글")
        #expect(!h.keyboard.log.contains("paste"))
    }

    @Test("E8: caret inside a word → refused; punctuation after the caret is fine")
    func caretInsideWord() async {
        let inside = Harness("gks|rmf")
        #expect(await inside.engine.convert(direction: .englishToKorean) == .refused(.caretInsideWord))
        #expect(inside.doc.marked == "gks|rmf")
        let beforePunctuation = Harness("dkssud|. next")
        #expect(await beforePunctuation.engine.convert(direction: .auto).isSuccess)
        #expect(beforePunctuation.doc.marked == "안녕|. next")
    }

    @Test("E9: refused AX undo gives the caret back instead of leaving the word selected")
    func refusedUndoRestoresSelection() async {
        let h = Harness("foo gksrmf|")
        h.element.ignoresTextWrites = true // forces the paste path, which waits for modifiers
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        #expect(h.doc.marked == "foo 한글|")
        h.keyboard.modifiersHeldForPolls = 10_000
        #expect(await h.engine.undo() == .refused(.modifiersStillHeld))
        #expect(h.doc.marked == "foo 한글|")
    }

    @Test("E10: AX write that times out but lands is reported as converted, with undo")
    func timedOutWriteThatLands() async {
        let h = Harness("foo gksrmf|")
        h.element.timesOutButApplies = true
        #expect(await h.engine.convert(direction: .auto) == .converted(scope: .previousWord, method: .accessibility, direction: .englishToKorean))
        #expect(h.doc.marked == "foo 한글|")
        #expect(h.engine.canUndo)
        #expect(!h.keyboard.log.contains("paste"), "never paste on top of a write that may land")
    }

    @Test("E12: keyboard undo of a very long replacement is refused without sending keys")
    func longKeyboardUndo() async {
        let long = String(repeating: "뷁", count: 400)
        let h = Harness("[\(long)]", accessibility: false)
        #expect(await h.engine.convert(direction: .koreanToEnglish).isSuccess)
        let keysBefore = h.keyboard.log.count
        #expect(await h.engine.undo() == .refused(.textTooLong))
        #expect(h.keyboard.log.count == keysBefore)
    }

    @Test("E13: AX undo keeps the caret where the user left it")
    func undoAfterTypingMore() async {
        let h = Harness("foo gksrmf |")
        #expect(await h.engine.convert(direction: .auto).isSuccess)
        h.doc.replaceSelection(with: "abc")
        #expect(h.doc.marked == "foo 한글 abc|")
        #expect(await h.engine.undo().isSuccess)
        #expect(h.doc.marked == "foo gksrmf abc|")
    }

    @Test("Embedded terminal (VS Code integrated terminal) is unsupported; no keys sent")
    func embeddedTerminal() async {
        let h = Harness("dkssud|")
        h.element.looksLikeTerminal = true
        h.element.supportsSelection = false
        #expect(await h.engine.convert(direction: .auto) == .refused(.unsupportedApp))
        #expect(h.keyboard.log.isEmpty)
    }
}
