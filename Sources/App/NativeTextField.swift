import SwiftUI
import AppKit

/// An AppKit text field that keeps SwiftUI in sync however its text changes: real typing, Return, leaving the field,
/// or an accessibility client setting AXValue / performing AXConfirm (automation, VoiceOver, Voice Control).
/// SwiftUI's own TextField ignores AXValue changes, so automation edits never reached the model.
struct NativeTextField: NSViewRepresentable {
    enum Style { case plain, monospaced }

    @Binding var text: String
    var placeholder = ""
    var style: Style = .plain
    var identifier: String
    var label: String
    /// Called on Return, AXConfirm, AXValue set, or when editing ends. Return the text the field should show afterwards.
    var onCommit: ((String) -> String?)? = nil
    var onEditingChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CommitTextField {
        let f = CommitTextField()
        f.placeholderString = placeholder
        f.stringValue = text
        f.bezelStyle = .roundedBezel
        f.isBezeled = true
        f.lineBreakMode = .byClipping
        f.cell?.isScrollable = true
        f.cell?.sendsActionOnEndEditing = false
        if style == .monospaced { f.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        f.delegate = context.coordinator
        f.target = context.coordinator
        f.action = #selector(Coordinator.returnPressed(_:))
        f.setAccessibilityIdentifier(identifier)
        f.setAccessibilityLabel(label)
        f.coordinator = context.coordinator
        return f
    }

    func updateNSView(_ f: CommitTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text {
            f.stringValue = text
            // The model changed underneath an active edit (e.g. "Use best guess"): show the new value, not stale typing.
            if let editor = f.currentEditor() as? NSTextView, editor.string != text { editor.string = text; editor.selectAll(nil) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTextField
        init(_ p: NativeTextField) { parent = p }

        func commit(_ f: NSTextField) {
            let value = f.currentEditor()?.string ?? f.stringValue
            parent.text = value
            if let shown = parent.onCommit?(value) {
                parent.text = shown
                f.stringValue = shown
                if let editor = f.currentEditor() as? NSTextView { editor.string = shown; editor.selectAll(nil) }
            }
        }

        @objc func returnPressed(_ sender: NSTextField) { commit(sender) }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = f.currentEditor()?.string ?? f.stringValue
        }
        func controlTextDidBeginEditing(_ n: Notification) { parent.onEditingChanged?(true) }
        func controlTextDidEndEditing(_ n: Notification) {
            if let f = n.object as? NSTextField, parent.onCommit != nil { commit(f) }
            parent.onEditingChanged?(false)
        }
        // Escape in a timecode field restores the current value instead of leaving half-typed text.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)), parent.onCommit != nil, let f = control as? NSTextField {
                f.abortEditing()
                f.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

class CommitTextField: NSTextField {
    weak var coordinator: NativeTextField.Coordinator?

    // Automation and assistive apps set AXValue directly; treat that like typing the text and pressing Return.
    override func setAccessibilityValue(_ value: Any?) {
        guard let s = value as? String else { super.setAccessibilityValue(value); return }
        if let editor = currentEditor() as? NSTextView { editor.string = s } else { stringValue = s }
        coordinator?.commit(self)
    }

    override func accessibilityPerformConfirm() -> Bool {
        coordinator?.commit(self)
        return true
    }
}
