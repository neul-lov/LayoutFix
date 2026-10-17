import AppKit
import SwiftUI
import HangulLayout

struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Text(model.statusHeadline)
        if let status = model.lastStatus {
            Text("Last: \(status)")
        }

        Divider()

        Picker("Default Direction", selection: $model.direction) {
            ForEach(ConversionDirection.allCases, id: \.self) { direction in
                Text(direction.title).tag(direction)
            }
        }
        .pickerStyle(.inline)

        Divider()

        Section("Shortcuts") {
            ForEach(HotKeyAction.allCases) { action in
                Button("\(action.title)   \(model.comboText(for: action))") {
                    model.performFromMenu(action)
                }
                .disabled(!model.accessibilityTrusted || (action == .undo && !model.canUndo))
            }
        }

        Divider()

        if model.accessibilityTrusted {
            Text("Accessibility: allowed")
        } else {
            Button("Accessibility: not allowed — Set Up…") {
                model.showSettings(tab: .permissions)
            }
        }
        if !model.hotKeyProblems.isEmpty {
            Button("Fix Unavailable Shortcuts…") {
                model.showSettings(tab: .shortcuts)
            }
        }

        Divider()

        Button("Settings…") { model.showSettings() }
            .keyboardShortcut(",")
        Button("Quit LayoutFix") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { model.refreshPermission() }
    }
}
