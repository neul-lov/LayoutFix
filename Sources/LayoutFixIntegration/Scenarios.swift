import AppKit
import ApplicationServices
import Carbon.HIToolbox
import AccessibilityText
import ClipboardBridge
import ConversionEngine
import HangulLayout
import HotKeys

@MainActor
final class Scenarios {
    let report = Report()
    let scratch: URL
    let engine = ConversionEngine(focus: AXFocusProvider(), system: SystemState(),
                                  pasteboard: SystemPasteboard(), keys: CGKeystrokeSender())

    init(scratch: URL) {
        self.scratch = scratch
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ contents: String) -> URL {
        let url = scratch.appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The app that must be frontmost for engine calls and synthetic keys.
    private var target = ""

    private func convert(direction: ConversionDirection) async throws -> EngineOutcome {
        try requireFront(target)
        return await engine.convert(direction: direction)
    }

    private func undo() async throws -> EngineOutcome {
        try requireFront(target)
        return await engine.undo()
    }

    private func key(_ code: Int, _ flags: CGEventFlags = []) throws {
        try requireFront(target)
        Keys.tap(code, flags)
    }

    /// Presses ⌃ + key the way a person does: modifier keys down, key, modifier keys up.
    private func chord(_ code: Int) throws {
        try requireFront(target)
        Keys.chord(code, modifiers: [(kVK_Control, .maskControl)])
    }

    private func type(_ text: String) async throws {
        for ch in text {
            try requireFront(target)
            await Keys.type(String(ch))
        }
    }

    // MARK: TextEdit — native Cocoa text view, Accessibility path

    func textEdit() async throws {
        report.section("TextEdit (Cocoa NSTextView)")
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
        let url = file("textedit-test.txt", "")
        guard let app = await openAndActivate(url, bundleID: "com.apple.TextEdit") else {
            return report.check("TextEdit opened and frontmost", false)
        }
        let pid = app.processIdentifier
        target = "com.apple.TextEdit"
        guard await waitFor(5, { AX.focused(pid).map { AX.string($0, kAXRoleAttribute) == kAXTextAreaRole } ?? false }),
              let el = AX.focused(pid) else {
            let role = AX.focused(pid).flatMap { AX.string($0, kAXRoleAttribute) } ?? "none"
            return report.check("TextEdit text view focused", false, "pid \(pid), focused role \(role), front \(frontmostBundleID() ?? "nil")")
        }
        let pasteboardBefore = NSPasteboard.general.changeCount

        func arrange(_ text: String, caret: Int? = nil, selection: (Int, Int)? = nil) {
            AX.setValue(el, text)
            if let selection { AX.setRange(el, selection.0, selection.1) } else { AX.setRange(el, caret ?? text.utf16.count, 0) }
        }

        arrange("hello dkssudgktpdy")
        var outcome = try await convert(direction: .auto)
        report.check("previous word → 안녕하세요 via Accessibility",
                     outcome == .converted(scope: .previousWord, method: .accessibility, direction: .englishToKorean), "\(outcome)")
        report.check("text is “hello 안녕하세요”", AX.value(el) == "hello 안녕하세요", AX.value(el) ?? "nil")
        report.check("caret restored at end", AX.range(el).map { $0 == (11, 0) } ?? false, "\(String(describing: AX.range(el)))")

        outcome = try await undo()
        report.check("undo succeeded", outcome == .undone(method: .accessibility), "\(outcome)")
        report.check("original text restored", AX.value(el) == "hello dkssudgktpdy", AX.value(el) ?? "nil")
        report.check("caret restored after undo", AX.range(el).map { $0 == (18, 0) } ?? false, "\(String(describing: AX.range(el)))")

        arrange("gksrmf and more", selection: (0, 6))
        outcome = try await convert(direction: .englishToKorean)
        report.check("selected text converted", AX.value(el) == "한글 and more", AX.value(el) ?? "nil")
        report.check("converted text left selected", AX.range(el).map { $0 == (0, 2) } ?? false)
        outcome = try await undo()
        report.check("undo re-selects original", AX.value(el) == "gksrmf and more" && AX.range(el).map { $0 == (0, 6) } == true)

        arrange("dkssud   world", caret: 9)
        outcome = try await convert(direction: .auto)
        report.check("word before caret with trailing spaces, mid-text", AX.value(el) == "안녕   world" && AX.range(el).map { $0 == (5, 0) } == true,
                     "\(AX.value(el) ?? "nil") \(String(describing: AX.range(el)))")

        arrange("인사 안녕")
        outcome = try await convert(direction: .koreanToEnglish)
        report.check("Korean → English keystrokes", AX.value(el) == "인사 dkssud", AX.value(el) ?? "nil")

        arrange("say hello")
        outcome = try await convert(direction: .auto)
        report.check("auto refuses English word (no change)", outcome == .refused(.looksLikeEnglish) && AX.value(el) == "say hello", "\(outcome)")

        arrange("total 123, ok?", selection: (6, 4))
        outcome = try await convert(direction: .auto)
        report.check("nothing to convert → untouched", outcome == .refused(.unchanged) && AX.value(el) == "total 123, ok?", "\(outcome)")

        arrange("line one\n")
        outcome = try await convert(direction: .auto)
        report.check("caret at line start → nothing", outcome == .refused(.nothingToConvert) && AX.value(el) == "line one\n", "\(outcome)")

        arrange("gksrmf")
        _ = try await convert(direction: .auto)
        AX.setValue(el, "edited meanwhile")
        outcome = try await undo()
        report.check("undo refused after the text changed", outcome == .refused(.undoTargetChanged) && AX.value(el) == "edited meanwhile", "\(outcome)")

        report.check("clipboard never touched on the AX path", NSPasteboard.general.changeCount == pasteboardBefore)

        AX.setValue(el, "")
        if !wasRunning { app.terminate() }
    }

    // MARK: Safari — WebKit text controls and a password field

    func safari() async throws {
        report.section("Safari (WebKit textarea, input, contenteditable, password)")
        let runID = ProcessInfo.processInfo.processIdentifier
        let title = "LayoutFix Test Page \(runID)"
        let page = file("layoutfix-test-\(runID).html", """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body spellcheck="false"><textarea id="ta" autofocus spellcheck="false" autocorrect="off" autocomplete="off">hello dkssud</textarea>
        <input id="inp" type="text" value="gksrmf world" spellcheck="false" autocorrect="off" autocomplete="off">
        <div id="ce" contenteditable="true" spellcheck="false" autocorrect="off">rmfjsep</div>
        <input id="pw" type="password" value=""></body></html>
        """)
        guard let app = await openAndActivate(page, bundleID: "com.apple.Safari") else {
            return report.check("Safari opened and frontmost", false)
        }
        let pid = app.processIdentifier
        target = "com.apple.Safari"
        let root = AX.appElement(pid)
        func byID(_ id: String) -> AXUIElement? { SafariTabs.element(root, domID: id) }
        _ = await waitFor(5) { !SafariTabs.tabButtons(root, prefix: title).isEmpty || SafariTabs.activeTitle(root) == title }
        _ = await SafariTabs.activate(root, prefix: title)
        guard await waitFor(8, { byID("ta") != nil }), let ta = byID("ta"), let inp = byID("inp"), let pw = byID("pw") else {
            return report.check("test page loaded", false)
        }

        let clipboard = ClipboardGuard()
        AX.setBool(ta, kAXFocusedAttribute, true)
        _ = await waitFor(2) { AX.focused(pid).map { CFEqual($0, ta) } ?? false }
        AX.setRange(ta, 12, 0)
        var outcome = try await convert(direction: .auto)
        report.check("textarea: previous word converted", AX.value(ta) == "hello 안녕", "\(outcome) → \(AX.value(ta) ?? "nil")")
        report.note("method: \(outcome)")
        outcome = try await undo()
        report.check("textarea: undo", AX.value(ta) == "hello dkssud", "\(outcome) → \(AX.value(ta) ?? "nil")")
        await sleep(0.3)
        report.check("textarea: clipboard restored after paste-based write", clipboard.isUnchanged)

        AX.setBool(inp, kAXFocusedAttribute, true)
        _ = await waitFor(2) { AX.focused(pid).map { CFEqual($0, inp) } ?? false }
        AX.setRange(inp, 0, 6)
        outcome = try await convert(direction: .englishToKorean)
        report.check("input: selection converted", AX.value(inp) == "한글 world", "\(outcome) → \(AX.value(inp) ?? "nil")")
        outcome = try await undo()
        report.check("input: undo", AX.value(inp) == "gksrmf world", "\(outcome) → \(AX.value(inp) ?? "nil")")
        report.note("input method: \(outcome)")
        await sleep(0.3)
        report.check("input: clipboard intact", clipboard.isUnchanged)
        clipboard.restoreIfChanged()

        if let ce = byID("ce") {
            AX.setBool(ce, kAXFocusedAttribute, true)
            await sleep(0.3)
            if let focused = AX.focused(pid), AX.range(focused) != nil {
                AX.setRange(focused, 7, 0)
                outcome = try await convert(direction: .auto)
                let text = AX.value(focused) ?? AX.string(ce, kAXValueAttribute) ?? ""
                report.check("contenteditable: previous word converted", text.contains("그런데"), "\(outcome) → \(text)")
                _ = try await undo()
            } else {
                report.skip("contenteditable", "focused element exposes no text range")
            }
        }

        AX.setBool(pw, kAXFocusedAttribute, true)
        _ = await waitFor(2) { AX.focused(pid).map { CFEqual($0, pw) } ?? false }
        try await type("dkssud")
        let changeCount = NSPasteboard.general.changeCount
        outcome = try await convert(direction: .auto)
        report.check("password field refused without reading", outcome == .refused(.secureInputActive) || outcome == .refused(.secureField), "\(outcome)")
        report.note("secure input active: \(IsSecureEventInputEnabled()), refusal: \(outcome)")
        report.check("password field: clipboard untouched", NSPasteboard.general.changeCount == changeCount)

        // Close our test tabs (including leftovers from earlier runs), never anything else.
        AX.setBool(ta, kAXFocusedAttribute, true)
        let closed = await SafariTabs.closeAll(root, prefix: "LayoutFix Test Page")
        report.note("closed \(closed) test tab(s)")
    }

    // MARK: Notes

    func notes() async throws {
        report.section("Notes")
        guard let app = await openAndActivate(nil, bundleID: "com.apple.Notes") else {
            return report.check("Notes opened and frontmost", false)
        }
        let pid = app.processIdentifier
        target = "com.apple.Notes"
        await sleep(1.0)
        try key(kVK_ANSI_N, .maskCommand) // new note
        // Only proceed in an empty, freshly created note; never type into an existing one.
        let ready = await waitFor(4) {
            guard let el = AX.focused(pid) else { return false }
            return AX.string(el, kAXRoleAttribute) == kAXTextAreaRole && (AX.value(el) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard ready, let el = AX.focused(pid) else {
            return report.skip("Notes", "could not confirm a new empty note; nothing typed")
        }
        try await type("LayoutFix test note (safe to delete)\ndkssudgktpdy")
        await sleep(0.5)
        var outcome = try await convert(direction: .auto)
        let after = AX.value(el) ?? ""
        report.check("previous word converted in Notes", after.hasSuffix("안녕하세요"), "\(outcome) → …\(after.suffix(12))")
        report.note("method: \(outcome)")
        outcome = try await undo()
        report.check("undo in Notes", (AX.value(el) ?? "").hasSuffix("dkssudgktpdy"), "\(outcome)")

        try await type(" gksrmf")
        await sleep(0.3)
        if let r = AX.range(el) {
            AX.setRange(el, r.0 - 6, 6)
            outcome = try await convert(direction: .englishToKorean)
            report.check("selection converted in Notes", (AX.value(el) ?? "").hasSuffix("dkssudgktpdy 한글"), "\(outcome)")
        }
        report.note("The test note “LayoutFix test note (safe to delete)” was left in Notes.")
    }

    // MARK: VS Code — Electron: keyboard + clipboard path

    func vscode() async throws {
        report.section("Visual Studio Code (Electron → clipboard fallback)")
        let url = file("vscode-test.txt", "hello dkssud")
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil else {
            return report.skip("VS Code", "not installed")
        }
        let guardClipboard = ClipboardGuard()
        guard let app = await openAndActivate(url, bundleID: "com.microsoft.VSCode") else {
            return report.check("VS Code opened and frontmost", false)
        }
        await sleep(3.0) // editor load
        _ = await activate(app)
        target = "com.microsoft.VSCode"

        func saveAndRead() async throws -> String {
            try key(kVK_ANSI_S, .maskCommand)
            await sleep(0.8)
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
        }

        try key(kVK_DownArrow, [.maskCommand, .maskNumericPad, .maskSecondaryFn]) // end of document
        await sleep(0.3)
        var outcome = try await convert(direction: .auto)
        var saved = try await saveAndRead()
        report.check("previous word converted", saved == "hello 안녕", "\(outcome) → \(saved)")
        report.note("method: \(outcome)")
        report.check("clipboard restored after conversion", guardClipboard.isUnchanged)

        outcome = try await undo()
        saved = try await saveAndRead()
        report.check("undo", saved == "hello dkssud", "\(outcome) → \(saved)")
        report.check("clipboard restored after undo", guardClipboard.isUnchanged)

        try key(kVK_ANSI_A, .maskCommand) // select all
        await sleep(0.2)
        outcome = try await convert(direction: .englishToKorean)
        saved = try await saveAndRead()
        report.check("selection converted", saved == "ㅗ디ㅣㅐ 안녕", "\(outcome) → \(saved)")

        // Caret at the very start: nothing before it, so nothing may change.
        try key(kVK_UpArrow, [.maskCommand, .maskNumericPad, .maskSecondaryFn])
        await sleep(0.2)
        outcome = try await convert(direction: .auto)
        saved = try await saveAndRead()
        report.check("caret at start → nothing changed", saved == "ㅗ디ㅣㅐ 안녕" && !outcome.isSuccess, "\(outcome) → \(saved)")

        report.check("user clipboard intact at the end", guardClipboard.isUnchanged)
        guardClipboard.restoreIfChanged()
        try key(kVK_ANSI_W, .maskCommand) // close the test file's editor
    }

    // MARK: The real LayoutFix.app: global hotkeys, settings window, login item, quit

    func appLevel(appPath: String) async throws {
        report.section("LayoutFix.app (global hotkeys while another app is active)")
        let hyper: UInt32 = UInt32(controlKey)
        let toKorean = KeyCombo(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: hyper)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/LayoutFix")
        process.arguments = ["--settings"]
        do { try process.run() } catch { return report.check("launch LayoutFix.app", false, "\(error)") }
        let pid = process.processIdentifier
        defer { if process.isRunning { process.terminate() } }

        let launched = await waitFor(5) { NSRunningApplication(processIdentifier: pid) != nil }
        let running = NSRunningApplication(processIdentifier: pid)
        report.check("app launched", launched && process.isRunning)
        report.check("no Dock icon (accessory activation policy)", running?.activationPolicy == .accessory, "\(String(describing: running?.activationPolicy.rawValue))")

        // Settings window was opened by --settings.
        let appEl = AX.appElement(pid)
        let settingsWindow: () -> AXUIElement? = {
            AX.children(appEl).first { AX.string($0, kAXTitleAttribute) == "LayoutFix Settings" }
        }
        report.check("settings window opened on request", await waitFor(5) { settingsWindow() != nil })

        // Launch at login through the real toggle in the settings UI.
        if let window = settingsWindow(),
           let toggle = AX.find(in: window, { AX.string($0, kAXIdentifierAttribute) == "launchAtLogin" }) {
            let before = (AX.attribute(toggle, kAXValueAttribute) as? NSNumber)?.intValue ?? -1
            AX.press(toggle)
            await sleep(1.5)
            let on = (AX.attribute(toggle, kAXValueAttribute) as? NSNumber)?.intValue ?? -1
            let errorText = AX.find(in: window) { (AX.string($0, kAXValueAttribute) ?? "").hasPrefix("Couldn't change") }
            report.check("launch at login: toggle turned on without error", before == 0 && on == 1 && errorText == nil,
                         "before=\(before) after=\(on) error=\(errorText.flatMap { AX.string($0, kAXValueAttribute) } ?? "none")")
            AX.press(toggle)
            await sleep(1.5)
            let off = (AX.attribute(toggle, kAXValueAttribute) as? NSNumber)?.intValue ?? -1
            report.check("launch at login: toggle turned off again", off == 0, "value=\(off)")
        } else {
            report.check("launch at login toggle found", false)
        }

        // Close the settings window: the app must keep running.
        if let window = settingsWindow(), let close = AX.element(window, kAXCloseButtonAttribute) {
            AX.press(close)
        }
        let closed = await waitFor(3) { settingsWindow() == nil }
        await sleep(1.0)
        report.check("settings window closed", closed)
        report.check("app still running after closing its window", process.isRunning)

        // Another process cannot take the same shortcut while LayoutFix holds it.
        let probe = HotKeyManager(systemShortcuts: { [] })
        let probeResult = probe.register([("probe", toKorean)])["probe"]
        report.check("cross-app conflict detected for ⌃G", probeResult == .alreadyInUse, "\(String(describing: probeResult))")
        probe.shutdown()

        // Hotkeys delivered while Safari (showing a local test page) is the active app.
        let runID = ProcessInfo.processInfo.processIdentifier
        let title = "LayoutFix Hotkey Test \(runID)"
        let page = file("hotkey-test-\(runID).html", """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body><textarea id="hk" autofocus spellcheck="false" autocorrect="off" autocomplete="off">gksrmf</textarea></body></html>
        """)
        let clipboard = ClipboardGuard()
        guard let safari = await openAndActivate(page, bundleID: "com.apple.Safari") else {
            return report.check("Safari ready for hotkey test", false)
        }
        let root = AX.appElement(safari.processIdentifier)
        let findField = { SafariTabs.element(root, domID: "hk") }
        _ = await waitFor(5) { !SafariTabs.tabButtons(root, prefix: title).isEmpty || SafariTabs.activeTitle(root) == title }
        _ = await SafariTabs.activate(root, prefix: title)
        guard await waitFor(8, { findField() != nil }), let el = findField() else {
            return report.check("hotkey test page loaded", false)
        }
        target = "com.apple.Safari"
        AX.setBool(el, kAXFocusedAttribute, true)
        _ = await waitFor(2) { AX.focused(safari.processIdentifier).map { CFEqual($0, el) } ?? false }
        AX.setValue(el, "gksrmf")
        AX.setRange(el, 6, 0)
        report.check("Safari is the active app (LayoutFix in the background)", frontmostBundleID() == "com.apple.Safari")

        try chord(kVK_ANSI_G)
        report.check("⌃G converted the previous word in Safari", await waitFor(4) { AX.value(el) == "한글" }, AX.value(el) ?? "nil")
        try chord(kVK_ANSI_Z)
        report.check("⌃Z restored it", await waitFor(4) { AX.value(el) == "gksrmf" }, AX.value(el) ?? "nil")
        try chord(kVK_ANSI_F)
        report.check("⌃F (auto) converted it", await waitFor(4) { AX.value(el) == "한글" }, AX.value(el) ?? "nil")
        try chord(kVK_ANSI_E)
        report.check("⌃E (Korean → English) converted it back", await waitFor(4) { AX.value(el) == "gksrmf" }, AX.value(el) ?? "nil")
        await sleep(0.5)
        report.check("clipboard intact after hotkey conversions", clipboard.isUnchanged)
        clipboard.restoreIfChanged()

        print("LAYOUTFIX_PID=\(pid)")
        let idleSeconds = Double(ProcessInfo.processInfo.environment["IDLE_SECONDS"] ?? "0") ?? 0
        if idleSeconds > 0 {
            report.note("leaving LayoutFix idle for \(Int(idleSeconds)) s for CPU sampling")
            await sleep(idleSeconds)
        }

        // Quit (SIGTERM goes through the normal quit path): hotkeys must be released.
        process.terminate()
        let exited = await waitFor(5) { !process.isRunning }
        report.check("app quits cleanly", exited)
        let after = HotKeyManager(systemShortcuts: { [] })
        report.check("hotkeys released after quit", after.register([("probe", toKorean)])["probe"] == .registered)
        after.shutdown()

        // Close our test tabs only.
        if frontmostBundleID() == "com.apple.Safari" {
            let closed = await SafariTabs.closeAll(root, prefix: "LayoutFix Hotkey Test")
            report.note("closed \(closed) test tab(s)")
        }
    }
}
