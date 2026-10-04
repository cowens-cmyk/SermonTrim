import SwiftUI

/// Scrubber with draggable In/Out handles. The kept region is highlighted; fades are drawn as ramps.
struct TimelineBar: View {
    @Environment(AppModel.self) private var model
    private let handleW: CGFloat = 14

    var body: some View {
        GeometryReader { geo in content(width: geo.size.width) }
    }

    private func content(width w: CGFloat) -> some View {
        let dur = max(model.duration, 0.001)
        func x(_ t: Double) -> CGFloat { CGFloat(t / dur) * w }
        func time(_ x: CGFloat) -> Double { Double(min(max(0, x), w) / w) * dur }
        return ZStack(alignment: .topLeading) {
                // Track
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: 40)
                    .offset(y: 18)

                // Kept region
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(2, x(model.outTime) - x(model.inTime)), height: 40)
                    .offset(x: x(model.inTime), y: 18)

                // Fade ramps
                if model.startKind != .none {
                    FadeRamp(rising: true)
                        .frame(width: max(2, x(min(model.inTime + model.startDuration, model.outTime)) - x(model.inTime)), height: 40)
                        .offset(x: x(model.inTime), y: 18)
                }
                if model.endKind != .none {
                    let a = x(max(model.outTime - model.endDuration, model.inTime))
                    FadeRamp(rising: false)
                        .frame(width: max(2, x(model.outTime) - a), height: 40)
                        .offset(x: a, y: 18)
                }

                // Suggested markers
                if case .ready(let d) = model.detectState {
                    ForEach(d.starts) { c in Marker(color: .green).offset(x: x(c.time) - 4, y: 12) }
                    ForEach(d.ends) { c in Marker(color: .orange).offset(x: x(c.time) - 4, y: 12) }
                }

                // Scrub surface
                Color.clear
                    .contentShape(Rectangle())
                    .frame(height: 40)
                    .offset(y: 18)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        model.player.pause()
                        model.seek(to: model.snap(time(v.location.x)))
                    })

                // Handles
                Handle(label: "In")
                    .offset(x: x(model.inTime) - handleW / 2, y: 12)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                        model.setIn(time(v.location.x)); model.seek(to: model.inTime)
                    })
                Handle(label: "Out")
                    .offset(x: x(model.outTime) - handleW / 2, y: 12)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                        model.setOut(time(v.location.x)); model.seek(to: model.outTime)
                    })

                // Playhead
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: 56)
                    .shadow(radius: 2)
                    .offset(x: x(model.currentTime) - 1, y: 10)
                    .allowsHitTesting(false)

            }
            .coordinateSpace(name: "timeline")
    }
}

private struct Handle: View {
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.clear)
                .frame(width: 14, height: 52)
                .glassEffect(.regular.tint(label == "In" ? .green.opacity(0.5) : .orange.opacity(0.5)).interactive(),
                             in: .rect(cornerRadius: 5))
        }
        .overlay(alignment: .top) {
            Text(label).font(.system(size: 9, weight: .bold)).fixedSize().offset(y: -10).foregroundStyle(.secondary)
        }
        .frame(width: 14, height: 52)
        .contentShape(Rectangle())
    }
}

private struct Marker: View {
    let color: Color
    var body: some View {
        Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(color)
    }
}

private struct FadeRamp: View {
    let rising: Bool
    var body: some View {
        LinearGradient(colors: [.black.opacity(rising ? 0.75 : 0), .black.opacity(rising ? 0 : 0.75)], startPoint: .leading, endPoint: .trailing)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .allowsHitTesting(false)
    }
}

struct BladeCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 8) {
            Label("Blade at \(formatTimecode(model.currentTime, frameRate: model.frameRate))", systemImage: "scissors")
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
            HStack(spacing: 8) {
                Button { model.bladeRemoveBefore() } label: { Label("Cut Before", systemImage: "arrow.left.to.line") }
                    .keyboardShortcut("[", modifiers: [])
                Button { model.bladeRemoveAfter() } label: { Label("Cut After", systemImage: "arrow.right.to.line") }
                    .keyboardShortcut("]", modifiers: [])
                Button("Cancel") { model.bladeOpen = false }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Text("[  removes everything before  ·  ]  removes everything after")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .frame(width: 340)
    }
}
