import AppKit
import SwiftUI

struct ShelfSearchField: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    let register: (NSTextField) -> Void
    let changed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = .labelColor
        field.placeholderString = L("搜索")
        field.setAccessibilityLabel(L("搜索历史记录"))
        field.delegate = context.coordinator
        register(field)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: SearchField, context: Context) {
        field.placeholderString = L("搜索")
        field.setAccessibilityLabel(L("搜索历史记录"))
        context.coordinator.parent = self
        field.synchronizeText(text)
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ShelfSearchField
        init(_ parent: ShelfSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
                  parent.text != field.stringValue else { return }
            parent.text = field.stringValue
            parent.changed()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.submit()
            return true
        }
    }
    final class SearchField: NSTextField {
        func synchronizeText(_ value: String) {
            // SwiftUI can deliver an older value during search expansion; never overwrite the active field editor.
            guard currentEditor() == nil, stringValue != value else { return }
            stringValue = value
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if self.currentEditor() !== window.firstResponder { window.makeFirstResponder(self) }
            }
        }
        override func selectText(_ sender: Any?) {
            if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            super.selectText(sender)
            if let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted, let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() {
                // Native text fields select existing text on focus, including the first typed character.
                editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            }
            return accepted
        }
    }
}
