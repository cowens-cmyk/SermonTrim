import SwiftUI

struct SettingsView: View {
    @AppStorage("endPhrases") private var endPhrases = MarkerSettings().endPhrases.joined(separator: "\n")
    @AppStorage("startPhrases") private var startPhrases = MarkerSettings().startPhrases.joined(separator: "\n")
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Wait after the closing words") {
                Stepper(value: Bindable(model).tailSeconds, in: 0...20, step: 1) {
                    Text("\(Int(model.tailSeconds)) seconds before the fade begins")
                }
            }
            Section("Phrases that suggest the end of the message (one per line)") {
                TextEditor(text: $endPhrases).font(.system(.body, design: .monospaced)).frame(height: 110)
            }
            Section("Phrases that suggest the start of the message (one per line)") {
                TextEditor(text: $startPhrases).font(.system(.body, design: .monospaced)).frame(height: 110)
            }
            Button("Restore defaults") {
                endPhrases = MarkerSettings().endPhrases.joined(separator: "\n")
                startPhrases = MarkerSettings().startPhrases.joined(separator: "\n")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
