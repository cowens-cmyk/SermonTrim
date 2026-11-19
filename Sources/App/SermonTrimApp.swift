import SwiftUI

/// Receives files and `sermontrim://` links from Finder, `open`, and other apps, plus a video path given as a launch
/// argument, and hands them to the model once the window exists.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pending: [OpenRequest] = []
    @MainActor var handler: ((OpenRequest) -> Void)? { didSet { flush() } }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Otherwise AppKit turns a video path in the launch arguments into an "open document" launch, and SwiftUI then
        // never creates the main window. We read the arguments ourselves below.
        UserDefaults.standard.set(false, forKey: "NSTreatUnknownArgumentsAsOpen")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let r = OpenRequest.fromArguments(Array(CommandLine.arguments.dropFirst())) { MainActor.assumeIsolated { enqueue(r) } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { for u in urls { if let r = OpenRequest(url: u) { enqueue(r) } } }
    }

    @MainActor private func enqueue(_ r: OpenRequest) {
        pending.append(r)
        flush()
        // Launched by a file or link (Finder, `open`), SwiftUI may not have made the window yet: ask for it.
        if handler == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { Self.showMainWindow() } } }
    }

    @MainActor static func showMainWindow() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Sermon Trim" }) {
            w.makeKeyAndOrderFront(nil)
        } else if let item = NSApp.windowsMenu?.items.first(where: { $0.title == "Sermon Trim" }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    @MainActor private func flush() {
        guard let handler, !pending.isEmpty else { return }
        // Only the last video matters: the window shows one at a time.
        let r = pending.removeLast()
        pending.removeAll()
        handler(r)
        NSApp.activate()
    }
}

@main
struct SermonTrimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Sermon Trim", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 760)
                .onAppear { appDelegate.handler = { [model] in model.handle($0) } }
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    await Updater.checkAndPrompt(silentIfCurrent: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 960)
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
