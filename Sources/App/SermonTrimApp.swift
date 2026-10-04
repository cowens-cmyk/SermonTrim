import SwiftUI

@main
struct SermonTrimApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Sermon Trim", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .onOpenURL { model.open($0) }
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    await Updater.checkAndPrompt(silentIfCurrent: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 880)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.checkAndPrompt(silentIfCurrent: false) } }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { model.openPanel() }.keyboardShortcut("o")
                Button("Batch Auto-Trim…") { model.showBatch = true }.keyboardShortcut("b", modifiers: [.command, .option])
            }
            CommandMenu("Edit Points") {
                Button("Blade at Playhead") { model.openBlade() }
                    .keyboardShortcut("b")
                    .disabled(!model.hasFile)
                Button("Preview Start") { model.previewStart() }.keyboardShortcut("1").disabled(!model.hasFile)
                Button("Preview End") { model.previewEnd() }.keyboardShortcut("2").disabled(!model.hasFile)
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
