import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The suggestions scroll on their own, so the transcript below always keeps room, even in a short window.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Auto-detect").font(.title3.weight(.semibold))
                    Text("Transcribes the audio on this Mac and suggests where the message starts and ends. Nothing leaves your computer.")
                        .font(.footnote).foregroundStyle(.secondary)
                    detectSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .layoutPriority(1)

            Divider()
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                if let t = model.transcript { Text("\(t.words.count) words").font(.caption).foregroundStyle(.secondary) }
            }
            if model.transcript != nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    NativeTextField(text: $search, placeholder: "Search transcript", identifier: "transcript-search", label: "Search transcript",
                                    onEditingChanged: { model.typingInField = $0 })
                }
                TranscriptList(search: search)
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .layoutPriority(1)
            } else {
                Text("No transcript yet.").foregroundStyle(.secondary).font(.footnote)
                Spacer()
            }
        }
        .padding(16)
        .disabled(!model.hasFile)
    }

    @ViewBuilder private var detectSection: some View {
        switch model.detectState {
        case .idle:
            Button { model.detect() } label: { Label(model.transcript == nil ? "Find start & end" : "Find start & end (use saved transcript)", systemImage: "wand.and.stars") }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("find-start-end")
        case .working(let stage, let f):
            VStack(alignment: .leading, spacing: 6) {
                if let f { ProgressView(value: f) } else { ProgressView().controlSize(.small) }
                Text(stage).font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Text(msg).foregroundStyle(.red).font(.footnote)
            Button("Try again") { model.detect() }.buttonStyle(.glass)
        case .ready(let d):
            VStack(alignment: .leading, spacing: 10) {
                Button { model.applyBestGuess() } label: { Label("Use best guess for start and end", systemImage: "checkmark.circle") }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("use-best-guess")
                HStack {
                    Text("Wait after the last word")
                    Stepper(value: Bindable(model).tailSeconds, in: 0...20, step: 1) { Text("\(Int(model.tailSeconds)) s").monospacedDigit() }
                }
                .font(.footnote)
                candidates("Start of message", d.starts, color: .green, apply: model.applyStart, isStart: true)
                candidates("End of message", d.ends, color: .orange, apply: model.applyEnd, isStart: false)
                ForEach(d.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                Button("Run again") { model.detect() }.buttonStyle(.glass).controlSize(.small)
            }
        }
    }

    private func candidates(_ title: String, _ items: [MarkerCandidate], color: Color, apply: @escaping (MarkerCandidate) -> Void, isStart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "diamond.fill").font(.subheadline.weight(.semibold)).foregroundStyle(color)
            if items.isEmpty { Text("No clear match found.").font(.caption).foregroundStyle(.secondary) }
            ForEach(items) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Button(formatTimecode(c.time, frameRate: model.frameRate)) { model.player.pause(); model.seek(to: max(0, c.time - (isStart ? 2 : 6))) }
                            .buttonStyle(.link).font(.system(.callout, design: .monospaced))
                        Text(c.source.rawValue).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                        Spacer()
                        Button("Use") { apply(c) }.buttonStyle(.glass).controlSize(.small)
                            .accessibilityLabel("Use \(isStart ? "start" : "end") \(formatTimecode(c.time, frameRate: model.frameRate))")
                    }
                    if !c.surrounding.isEmpty {
                        Text((isStart ? "Before: …" : "After: ") + c.surrounding + (isStart ? "" : "…"))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    Text(c.context).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    if !c.reason.isEmpty { Text(c.reason).font(.caption2).foregroundStyle(.tertiary) }
                }
                .padding(8)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
        }
    }
}

struct TranscriptList: View {
    @Environment(AppModel.self) private var model
    let search: String

    var body: some View {
        let all = model.transcript?.sentences ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        let sentences = all.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        let now = model.currentTime
        let active = sentences.firstIndex { now >= $0.start && now < $0.end + 0.3 }
        ScrollView {
            if !query.isEmpty && sentences.isEmpty {
                Text("No lines contain “\(query)”.").font(.footnote).foregroundStyle(.secondary).padding(6)
            }
            // A filtered list is short, so build every row (all of them reach the accessibility tree); the full
            // transcript stays lazy for speed.
            if query.isEmpty {
                LazyVStack(alignment: .leading, spacing: 2) { rows(sentences, active: active) }
            } else {
                VStack(alignment: .leading, spacing: 2) { rows(Array(sentences.prefix(400)), active: active) }
            }
        }
        .accessibilityIdentifier("transcript-list")
        .accessibilityLabel(query.isEmpty ? "Transcript, \(all.count) lines" : "Transcript, \(sentences.count) lines containing \(query)")
    }

    @ViewBuilder private func rows(_ sentences: [Transcript.Sentence], active: Int?) -> some View {
        ForEach(Array(sentences.enumerated()), id: \.offset) { i, s in
            Button { model.player.pause(); model.seek(to: s.start) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text(MarkerDetector.clock(s.start)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text(s.text).font(.callout).multilineTextAlignment(.leading)
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(i == active ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(MarkerDetector.clock(s.start)) \(s.text)")
            .accessibilityHint("Moves the playhead here")
            .accessibilityIdentifier("transcript-line-\(Int(s.start * 100))")
        }
    }
}
