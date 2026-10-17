// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LayoutFix",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LayoutFix", targets: ["LayoutFixApp"]),
    ],
    targets: [
        // Pure Swift: Dubeolsik key mapping + Hangul jamo composition. No AppKit.
        .target(name: "HangulLayout"),

        // Accessibility (AX) layer: focused element, selection, caret, replacement, secure-field checks.
        .target(name: "AccessibilityText"),

        // Clipboard handling and the synthetic copy/paste keystrokes used by the fallback path.
        .target(name: "ClipboardBridge"),

        // Global hotkeys via Carbon RegisterEventHotKey, with conflict detection.
        .target(name: "HotKeys"),

        // Orchestration: decides AX vs. clipboard path, word boundaries, undo records.
        .target(
            name: "ConversionEngine",
            dependencies: ["HangulLayout", "AccessibilityText", "ClipboardBridge"]
        ),

        // SwiftUI menu bar app.
        .executableTarget(
            name: "LayoutFixApp",
            dependencies: ["HangulLayout", "AccessibilityText", "ClipboardBridge", "HotKeys", "ConversionEngine"]
        ),

        // Drives the real engine against real apps (TextEdit, Safari, Notes, VS Code). Not shipped.
        .executableTarget(
            name: "LayoutFixIntegration",
            dependencies: ["HangulLayout", "AccessibilityText", "ClipboardBridge", "HotKeys", "ConversionEngine"]
        ),

        .testTarget(name: "HangulLayoutTests", dependencies: ["HangulLayout"]),
        .testTarget(name: "ConversionEngineTests", dependencies: ["ConversionEngine", "HangulLayout", "AccessibilityText", "ClipboardBridge"]),
        .testTarget(name: "ClipboardBridgeTests", dependencies: ["ClipboardBridge"]),
        .testTarget(name: "HotKeysTests", dependencies: ["HotKeys"]),
    ]
)
