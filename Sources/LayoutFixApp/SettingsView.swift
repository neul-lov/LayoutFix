import SwiftUI
import HangulLayout
import HotKeys

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ShortcutSettings(model: model)
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(SettingsTab.shortcuts)
            PermissionSettings(model: model)
                .tabItem { Label("Permissions & Privacy", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Default direction", selection: $model.direction) {
                    ForEach(ConversionDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(model.direction.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Used by the “Convert” shortcut. The English → Korean and Korean → English shortcuts always use their own direction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin == .enabled || model.launchAtLogin == .requiresApproval },
                    set: { model.setLaunchAtLogin($0) }))
                    .disabled(model.launchAtLogin == .unavailable)
                    // Grouped-form switches otherwise reach VoiceOver without a name.
                    .accessibilityLabel("Launch at login")
                    .accessibilityIdentifier("launchAtLogin")
                switch model.launchAtLogin {
                case .requiresApproval:
                    HStack {
                        Text("Waiting for approval in System Settings › General › Login Items.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open Login Items") { LaunchAtLogin.openSystemSettings() }
                            .controlSize(.small)
                    }
                case .unavailable:
                    Text("Only available when running the LayoutFix.app bundle.")
                        .font(.caption).foregroundStyle(.secondary)
                case .enabled, .disabled:
                    EmptyView()
                }
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Clipboard fallback for apps without Accessibility text", isOn: $model.allowClipboardFallback)
                    .accessibilityLabel("Clipboard fallback for apps without Accessibility text")
                    .accessibilityIdentifier("clipboardFallback")
                Text("Uses ⌘C, ⌥⇧← and ⌘V when an app (e.g. VS Code) doesn't expose its text. Your clipboard is restored afterwards unless you copy something new meanwhile. Clipboard history apps may still record the copied word.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Beep when nothing was converted", isOn: $model.beepOnFailure)
                    .accessibilityLabel("Beep when nothing was converted")
                    .accessibilityIdentifier("beepOnFailure")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(HotKeyAction.allCases) { action in
                    GridRow {
                        Text(action.title)
                        HotKeyRecorder(
                            combo: model.hotKeys[action] ?? nil,
                            onChange: { model.setHotKey($0, for: action) },
                            onRecordingChange: { model.setRecording($0) })
                        StatusLabel(result: model.hotKeyResults[action] ?? .disabled)
                    }
                }
            }
            Text("Click a shortcut, then press the new keys. Esc cancels, Delete clears. Shortcuts need ⌃, or ⌘ together with ⌥ (or a function key), so they don't block typing or app shortcuts. Conflicts with macOS shortcuts and other apps are detected when saving.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Restore Defaults") { model.restoreDefaultHotKeys() }
            Spacer()
        }
        .padding(.top, 8)
    }
}

private struct StatusLabel: View {
    let result: HotKeyRegistrationResult

    var body: some View {
        switch result {
        case .registered:
            Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .disabled:
            Label("Off", systemImage: "minus.circle").foregroundStyle(.secondary)
        default:
            Label(result.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 200, alignment: .leading)
        }
    }
}

private struct PermissionSettings: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: model.accessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(model.accessibilityTrusted ? .green : .orange)
                        .font(.title)
                    VStack(alignment: .leading) {
                        Text(model.accessibilityTrusted ? "Accessibility access is allowed" : "Accessibility access is needed")
                            .font(.headline)
                        Text(model.accessibilityTrusted
                             ? "Shortcuts can read and replace text in other apps."
                             : "Until it is allowed, shortcuts do nothing and no text is read.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("Why: LayoutFix reads the selected text (or the word before the cursor) in the app you are using and replaces it with the converted text. macOS allows that only for apps with Accessibility access. The same permission lets the clipboard fallback send ⌘C/⌘V.")
                    .fixedSize(horizontal: false, vertical: true)

                if !model.accessibilityTrusted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How to allow it:").bold()
                        Text("1. Click “Open Privacy & Security”.")
                        Text("2. Under Accessibility, turn on LayoutFix (use + to add it if it's missing).")
                        Text("3. Come back here; the status updates automatically.")
                    }
                    HStack {
                        Button("Open Privacy & Security") { model.openAccessibilitySettings() }
                            .buttonStyle(.borderedProminent)
                        Button("Show System Prompt") { model.requestAccessibilityPrompt() }
                    }
                    Text("After rebuilding or moving the app, macOS may treat it as a different app: remove the old LayoutFix entry and allow it again.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Privacy").font(.headline)
                    Text("• Everything happens on this Mac. LayoutFix contains no network code and uses no external services.")
                    Text("• Your text is never logged or written to disk. Only the last conversion is kept in memory, for Undo, and it is cleared after 2 minutes or when you quit.")
                    Text("• Text is read only when you press a shortcut. LayoutFix does not monitor or record typing.")
                    Text("• Password fields, Secure Input, password managers and system authentication dialogs are skipped without reading anything.")
                    Text("• The clipboard fallback must read your clipboard to restore it. macOS asks once whether LayoutFix may paste from other apps; if you deny it, the fallback is skipped and your clipboard is never touched.")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
    }
}
