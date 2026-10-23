import AppKit
import SwiftUI

struct ShelfSearchField: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    let register: (NSTextField) -> Void
    let changed: () -> Void
    var focusChanged: (Bool) -> Void = { _ in }
    var moveSuggestion: (Int) -> Bool = { _ in false }

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
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focusChanged(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focusChanged(false) }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
                  parent.text != field.stringValue else { return }
            parent.text = field.stringValue
            parent.changed()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.moveDown(_:)) { return parent.moveSuggestion(1) }
            if commandSelector == #selector(NSResponder.moveUp(_:)) { return parent.moveSuggestion(-1) }
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
        func focusForSearch() {
            guard let window else { return }
            if window.isVisible { NSApp.activate(ignoringOtherApps: true) }
            if currentEditor() !== window.firstResponder { window.makeFirstResponder(self) }
        }
        @discardableResult func beginTyping(with event: NSEvent) -> Bool {
            focusForSearch()
            guard let editor = currentEditor() as? NSTextView else { return false }
            // Deliver the original first key to the input method, not a synthesized string.
            editor.interpretKeyEvents([event])
            return true
        }
        override func selectText(_ sender: Any?) {
            if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            super.selectText(sender)
            if let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
        override func becomeFirstResponder() -> Bool {
            if window?.isVisible == true { NSApp.activate(ignoringOtherApps: true) }
            let accepted = super.becomeFirstResponder()
            if accepted, let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() {
                // Native text fields select existing text on focus, including the first typed character.
                editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            }
            return accepted
        }
    }
}
