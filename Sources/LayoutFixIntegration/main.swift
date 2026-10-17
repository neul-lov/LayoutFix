import AppKit
import ApplicationServices

// Integration harness: runs the real engine (and the built app) against real apps.
//   LayoutFixIntegration [textedit|safari|notes|vscode|app|all] [--app path/to/LayoutFix.app]
// It needs Accessibility access for the process that launches it, and it takes over
// the keyboard focus while running.

let arguments = Array(CommandLine.arguments.dropFirst())
let scenario = arguments.first(where: { !$0.hasPrefix("--") && !$0.hasSuffix(".app") }) ?? "all"
let appPath = arguments.firstIndex(of: "--app").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    ?? "build/LayoutFix.app"
let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAYOUTFIX_SCRATCH"]
    ?? NSTemporaryDirectory()).appendingPathComponent("layoutfix-integration")

let application = NSApplication.shared
application.setActivationPolicy(.accessory) // a run loop for pasteboard callbacks, no Dock icon

Task { @MainActor in
    guard AXIsProcessTrusted() else {
        print("This process has no Accessibility access; cannot run integration tests.")
        exit(2)
    }
    let s = Scenarios(scratch: scratch)
    if scenario == "cleanup" {
        // Close leftover test tabs from earlier runs (only titles with our test prefixes).
        if let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first,
           await activate(safari) {
            let root = AX.appElement(safari.processIdentifier)
            for prefix in SafariTabs.testPrefixes {
                print("closed \(await SafariTabs.closeAll(root, prefix: prefix)) tab(s) starting with “\(prefix)”")
            }
        }
        exit(0)
    }
    let all = scenario == "all"
    let runs: [(String, () async throws -> Void)] = [
        ("textedit", s.textEdit), ("safari", s.safari), ("notes", s.notes), ("vscode", s.vscode),
        ("app", { try await s.appLevel(appPath: appPath) }),
    ]
    for (name, run) in runs where all || scenario == name {
        do {
            try await run()
        } catch let lost as FocusLost {
            s.report.check("\(name): focus stayed on \(lost.expected)", false,
                           "focus moved to \(lost.actual ?? "nothing"); scenario stopped so no test input reached that app")
        } catch {
            s.report.check("\(name)", false, "\(error)")
        }
    }
    // Synthetic shortcuts (the app's and the harness's) must not leave a modifier "held".
    try? await Task.sleep(for: .milliseconds(300))
    s.report.check("no modifier key left held after the run", !Keys.anyModifierHeld)
    print("\nRESULT: \(s.report.passed) passed, \(s.report.failed) failed, \(s.report.skipped) skipped")
    exit(s.report.failed == 0 ? 0 : 1)
}
application.run()
