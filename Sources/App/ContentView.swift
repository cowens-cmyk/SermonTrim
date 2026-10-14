import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        Group {
            if model.hasFile {
                EditorView()
            } else {
                WelcomeView()
            }
        }
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            model.open(u)
            return true
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Open", systemImage: "folder") { model.openPanel() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Blade", systemImage: "scissors") { model.openBlade() }
                    .disabled(!model.hasFile)
                    .help("Blade at playhead (⌘B)")
                Button("Auto-detect panel", systemImage: "sidebar.trailing") { model.showInspector.toggle() }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true; model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .sheet(isPresented: $model.showBatch) { BatchView().environment(model) }
        .sheet(isPresented: $model.showDetailsSheet) { SermonDetailsSheet().environment(model).interactiveDismissDisabled() }
        .onKeyPress(.space) { guard model.hasFile, !Self.isTyping else { return .ignored }; model.togglePlay(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "iIoO"), phases: .down) { press in
            guard model.hasFile, !Self.isTyping else { return .ignored }
            if press.characters.lowercased() == "i" { model.setIn() } else { model.setOut() }
            return .handled
        }
        .onKeyPress(.leftArrow) { model.hasFile && !Self.isTyping ? { model.step(frames: -1); return .handled }() : .ignored }
        .onKeyPress(.rightArrow) { model.hasFile && !Self.isTyping ? { model.step(frames: 1); return .handled }() : .ignored }
        .onKeyPress(characters: CharacterSet(charactersIn: ",."), phases: .down) { press in
            guard model.hasFile, !Self.isTyping else { return .ignored }
            model.jump(seconds: press.characters == "," ? -1 : 1)
            return .handled
        }
        .alert("Couldn't open that file", isPresented: .constant(model.loadError != nil)) {
            if model.loadErrorIsPermission {
                Button("Open Privacy Settings") { NSWorkspace.shared.open(ErrorExplainer.privacySettingsURL); model.loadError = nil }
            }
            Button("OK") { model.loadError = nil }
        } message: { Text(model.loadError ?? "") }
    }
}

extension ContentView {
    /// True while a text field (title, timecodes, search…) has the keyboard, so shortcuts don't steal typing.
    static var isTyping: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText || NSApp.keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "scissors")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a sermon video here")
                .font(.title2.weight(.semibold))
            Text("Trim the start and end and add a fade — without re-exporting the whole file.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Video…") { model.openPanel() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EditorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            PlayerSurface(player: model.player)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) { NowBadge() }
                .overlay(alignment: .bottom) {
                    if model.bladeOpen { BladeCard().padding(14).transition(.scale(scale: 0.92).combined(with: .opacity)) }
                }
                .animation(.snappy(duration: 0.2), value: model.bladeOpen)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            TimelineBar()
                .frame(height: 74)
                .padding(.horizontal, 16)

            ControlsPanel()
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
    }
}

struct NowBadge: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Text(formatTimecode(model.currentTime, frameRate: model.frameRate))
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .padding(12)
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = false
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}
