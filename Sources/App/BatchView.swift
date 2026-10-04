import SwiftUI
import AppKit

struct BatchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let batch = model.batch
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Batch Auto-Trim").font(.title2.weight(.semibold))
                Spacer()
                Button("Add Files…") { model.openBatchPanel() }.buttonStyle(.glass).disabled(batch.running)
            }
            Text("Each file is transcribed on this Mac, the start and end are detected, and a trimmed copy is saved next to the original using your current fade settings (start: \(describe(model.startKind, model.startDuration)), end: \(describe(model.endKind, model.endDuration)), \(Int(model.tailSeconds)) s hold). Detection is a best guess — use “Open in Editor” to check any file.")
                .font(.footnote).foregroundStyle(.secondary)

            if batch.items.isEmpty {
                ContentUnavailableView("No files yet", systemImage: "film.stack", description: Text("Add one or more sermon videos."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(batch.items) { item in row(item) }
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }

            HStack {
                Button("Clear Finished") { batch.clearFinished() }.disabled(batch.running)
                Spacer()
                if batch.running {
                    Button("Stop") { batch.cancel() }.buttonStyle(.glass)
                } else {
                    Button("Close") { dismiss() }.buttonStyle(.glass)
                    Button("Start") {
                        batch.start(startFade: Transition(kind: model.startKind, duration: model.startDuration),
                                    endFade: Transition(kind: model.endKind, duration: model.endDuration),
                                    tail: model.tailSeconds, markerSettings: model.markerSettings)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!batch.items.contains { if case .waiting = $0.status { return true }; return false })
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }

    private func describe(_ k: TransitionKind, _ d: Double) -> String { k == .none ? "none" : "\(k.rawValue.lowercased()) \(String(format: "%g", d)) s" }

    @ViewBuilder private func row(_ item: BatchModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                switch item.status {
                case .waiting: Text("Waiting").foregroundStyle(.secondary)
                case .working(let stage, _): Text(stage).foregroundStyle(.secondary)
                case .done: Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if case .working(_, let f) = item.status {
                if let f { ProgressView(value: f) } else { ProgressView().controlSize(.small) }
            }
            if case .failed(let msg) = item.status { Text(msg).font(.caption).foregroundStyle(.secondary) }
            if let a = item.inTime, let b = item.outTime {
                Text("In \(formatTimecode(a, frameRate: 30))  ·  Out \(formatTimecode(b, frameRate: 30))" + (item.summary.isEmpty ? "" : "  ·  \(item.summary)"))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open in Editor") {
                    model.open(item.url, points: item.inTime.flatMap { a in item.outTime.map { (a, $0) } })
                    dismiss()
                }.buttonStyle(.link)
                if let out = item.output {
                    Button("Reveal Trimmed File") { NSWorkspace.shared.activateFileViewerSelecting([out]) }.buttonStyle(.link)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
