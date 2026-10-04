import SwiftUI

@main
struct SermonTrimApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .onOpenURL { model.open($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { model.openPanel() }.keyboardShortcut("o")
            }
            CommandMenu("Edit Points") {
                Button("Blade at Playhead") { model.openBlade() }
                    .keyboardShortcut("b")
                    .disabled(!model.hasFile)
                Divider()
                Button("Set In at Playhead") { model.setIn() }.keyboardShortcut("i", modifiers: [.command, .option]).disabled(!model.hasFile)
                Button("Set Out at Playhead") { model.setOut() }.keyboardShortcut("o", modifiers: [.command, .option]).disabled(!model.hasFile)
                Divider()
                Button("Export Trimmed Video") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(!model.hasFile || model.isExporting)
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}
