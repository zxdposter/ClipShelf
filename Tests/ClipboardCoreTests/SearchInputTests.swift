import AppKit
import Testing
import Combine
import SwiftUI
import ClipboardCore
@testable import ClipShelf

struct SearchInputTests {
    @Test @MainActor func returnWaitsForResultsAndFocusesWithoutCopying() async throws {
        _ = NSApplication.shared
        let item = Clip(kind: .text, text: "target", sourceName: "Test", sourceBundle: "test", items: [], identity: Data())
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.history = History(clips: [item])
        model.searchShown = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        let field = ShelfSearchField.SearchField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        window.contentView = field
        defer { window.contentView = nil }
        model.searchField = field
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor())
        model.query = "target"
        await model.focusSearchResults()
        #expect(window.firstResponder !== editor)
        #expect(model.selectedClips.map(\.id) == [item.id])
        #expect(model.copiedID == nil)
    }
    @Test @MainActor func suggestionNavigationDoesNotInterceptChineseComposition() throws {
        _ = NSApplication.shared
        var moves: [Int] = []
        var submits = 0
        let view = ShelfSearchField(text: .constant(""), submit: { submits += 1 }, register: { _ in }, changed: {}, moveSuggestion: { moves.append($0); return true })
        let delegate = view.makeCoordinator()
        let editor = NSTextView()
        let control = NSControl()
        #expect(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(moves == [1, -1])
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(!delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submits == 0)
        editor.unmarkText()
        #expect(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submits == 1)
    }
    @Test @MainActor func unchangedKeyboardAndSelectionDoNotRefreshTheShelf() {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.preferences.quickPasteModifier = .command
        model.resetSelection()
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for _ in 0..<100 {
            model.updateQuickPasteModifier([])
            model.resetSelection()
        }
        #expect(changes == 0)
        model.updateQuickPasteModifier(.command)
        let changesAfterPress = changes
        model.updateQuickPasteModifier(.command)
        #expect(changesAfterPress > 0)
        #expect(changes == changesAfterPress)
    }
    @Test @MainActor func compositionDoesNotFilterUntilChineseTextIsCommitted() throws {
        _ = NSApplication.shared
        var query = "previous"
        var updates = 0
        let view = ShelfSearchField(text: Binding(get: { query }, set: { query = $0 }), submit: {}, register: { _ in }, changed: { updates += 1 })
        let delegate = view.makeCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        let field = ShelfSearchField.SearchField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.stringValue = query
        field.delegate = delegate
        window.contentView = field
        defer { window.contentView = nil }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        for composition in ["n", "ni", "nih", "niha", "nihao"] {
            editor.setMarkedText(composition, selectedRange: NSRange(location: composition.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        #expect(query == "previous")
        #expect(updates == 0)
        editor.insertText("你好", replacementRange: editor.markedRange())
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(!editor.hasMarkedText())
        #expect(query == "previous你好")
        #expect(updates == 1)
    }
    @Test @MainActor func initialFocusAppendsWithoutSelectingExistingCharacters() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        let field = ShelfSearchField.SearchField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.stringValue = "a😀"
        window.contentView = field
        defer { window.contentView = nil }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 3, length: 0))
        editor.insertText("b", replacementRange: editor.selectedRange())
        #expect(editor.string == "a😀b")
        field.synchronizeText("")
        #expect(editor.string == "a😀b")
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
        field.selectText(nil)
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
        editor.selectAll(nil)
        #expect(editor.selectedRange().length == 4)
        editor.insertText("replacement", replacementRange: editor.selectedRange())
        #expect(editor.string == "replacement")
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        let marked = editor.markedRange()
        field.synchronizeText("")
        field.selectText(nil)
        #expect(editor.hasMarkedText())
        #expect(editor.markedRange() == marked)
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.searchField = field
        model.query = editor.string
        model.clearSearch()
        #expect(model.query.isEmpty)
        #expect(editor.string.isEmpty)
        #expect(!editor.hasMarkedText())
    }
}
