import SwiftUI

struct ControlsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    card("Trim") {
                        HStack(spacing: 14) {
                            pointEditor("In", value: Binding(get: { model.inTime }, set: { model.setIn($0) }), action: { model.setIn() }, key: "I")
                            pointEditor("Out", value: Binding(get: { model.outTime }, set: { model.setOut($0) }), action: { model.setOut() }, key: "O")
                        }
                        Text("Length \(formatTimecode(model.keptDuration, frameRate: model.frameRate))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    card("Start") {
                        TransitionPicker(kind: $model.startKind, duration: $model.startDuration, range: 0.25...3, label: "Fade in")
                    }
                    card("End") {
                        TransitionPicker(kind: $model.endKind, duration: $model.endDuration, range: 0.5...10, label: "Fade out")
                    }
                }

                HStack(spacing: 10) {
                    transport
                    Spacer(minLength: 12)
                    ExportButton()
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button { model.seek(to: model.inTime) } label: { Image(systemName: "backward.end.fill") }
                .help("Go to In point")
            Button { model.step(frames: -1) } label: { Image(systemName: "chevron.left") }
                .help("Back one frame (←)")
            Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                .buttonStyle(.glassProminent)
                .help("Play / pause (Space)")
            Button { model.step(frames: 1) } label: { Image(systemName: "chevron.right") }
                .help("Forward one frame (→)")
            Button { model.seek(to: model.outTime) } label: { Image(systemName: "forward.end.fill") }
                .help("Go to Out point")
            Divider().frame(height: 18)
            Button("Preview Start") { model.previewStart() }
            Button("Preview End") { model.previewEnd() }
            Divider().frame(height: 18)
            Button { model.openBlade() } label: { Label("Blade", systemImage: "scissors") }
                .help("Blade at playhead (⌘B)")
        }
        .buttonStyle(.glass)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func pointEditor(_ name: String, value: Binding<Double>, action: @escaping () -> Void, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TimecodeField(seconds: value, frameRate: model.frameRate)
            Button("Set \(name) (\(key))", action: action).buttonStyle(.glass).controlSize(.small)
        }
    }
}

struct TransitionPicker: View {
    @Binding var kind: TransitionKind
    @Binding var duration: Double
    let range: ClosedRange<Double>
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(label, selection: $kind) {
                ForEach(TransitionKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            HStack {
                Slider(value: $duration, in: range, step: 0.25).disabled(kind == .none)
                Text(String(format: "%.2f s", duration)).font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(kind == .none ? .tertiary : .secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

struct TimecodeField: View {
    @Binding var seconds: Double
    let frameRate: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("00:00:00:00", text: $text)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onChange(of: seconds, initial: true) { _, v in if !focused { text = formatTimecode(v, frameRate: frameRate) } }
    }

    private func commit() {
        if let v = parseTimecode(text, frameRate: frameRate) { seconds = v }
        text = formatTimecode(seconds, frameRate: frameRate)
    }
}

struct ExportButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            switch model.exportState {
            case .idle:
                if let pf = model.preflight {
                    Text(pf.summary).font(.footnote).foregroundStyle(pf.isHeavy ? .orange : .secondary)
                        .help("Everything outside the fades is copied without re-encoding, so the file stays about the same size.")
                }
            case .running(let stage, let fraction):
                ProgressView(value: fraction).frame(width: 160)
                Text(stage).font(.footnote).foregroundStyle(.secondary)
                Button("Cancel") { model.cancelExport() }.buttonStyle(.glass)
            case .done(let r):
                VStack(alignment: .trailing, spacing: 2) {
                    Text(r.outputURL.lastPathComponent).font(.footnote.weight(.medium)).lineLimit(1)
                    Text(String(format: "%@ · %.0f%% of original", ByteCountFormatter.string(fromByteCount: r.report.output.fileSize, countStyle: .file), r.report.sizeRatio * 100))
                        .font(.caption).foregroundStyle(r.report.looksTooLarge ? .orange : .secondary)
                }
                Button("Reveal in Finder") { model.revealOutput() }.buttonStyle(.glass)
            case .failed(let msg):
                Text(msg).font(.footnote).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 280, alignment: .trailing)
            }
            Button { model.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.isExporting)
                .help("Export trimmed video next to the original (⌘E)")
        }
    }
}

struct SermonDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var titleFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sermon Details").font(.title2.weight(.semibold))
                Spacer()
                progress
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("The Lord Sees", text: $model.sermonTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($titleFocused)
                    .onSubmit { if canSave { model.submitDetails() } }
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Date preached").font(.caption).foregroundStyle(.secondary)
                    DatePicker("Date preached", selection: $model.sermonDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(width: 240)
                    Button("Closest Sunday") { model.useClosestSunday(to: model.sermonDate) }
                        .buttonStyle(.glass).controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speaker").font(.caption).foregroundStyle(.secondary)
                    TextField("Pastor name", text: $model.speaker)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canSave { model.submitDetails() } }
                    if !model.recentSpeakers.isEmpty {
                        Text("Recent").font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                        FlowButtons(names: model.recentSpeakers) { model.speaker = $0 }
                    }
                    Text("Becomes a Finder tag. Separate several speakers with commas.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(model.outputFileName).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    ForEach(Tagging.speakers(from: model.speaker), id: \.self) {
                        Text($0).font(.caption2).padding(.horizontal, 7).padding(.vertical, 2).background(.tint.opacity(0.25), in: .capsule)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text("Saves to \(model.outputFolderName)").font(.footnote).foregroundStyle(.secondary)
                    Button("Change…") { model.chooseOutputFolder() }.buttonStyle(.link).font(.footnote)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))

            HStack {
                Button("Cancel Export", role: .destructive) { model.cancelExportFromSheet() }
                Spacer()
                Button("Skip") { model.skipDetails() }
                    .help("Save with the original filename and no tag")
                Button(model.exportFinishedWaiting ? "Save" : "Save When Done") { model.submitDetails() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { titleFocused = true }
    }

    private var canSave: Bool { !SermonNaming.sanitize(model.sermonTitle).isEmpty }

    @ViewBuilder private var progress: some View {
        switch model.exportState {
        case .running(let stage, let f):
            HStack(spacing: 8) {
                ProgressView(value: f).frame(width: 120)
                Text(f >= 1 && model.exportFinishedWaiting ? "Export ready" : stage).font(.caption).foregroundStyle(.secondary)
            }
        default: EmptyView()
        }
    }
}

/// Small wrapping row of buttons for recent speaker names.
struct FlowButtons: View {
    let names: [String]
    let action: (String) -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { ForEach(names.prefix(6), id: \.self) { n in Button(n) { action(n) }.buttonStyle(.glass).controlSize(.small) } }
            VStack(alignment: .leading) { ForEach(names.prefix(6), id: \.self) { n in Button(n) { action(n) }.buttonStyle(.glass).controlSize(.small) } }
        }
    }
}
