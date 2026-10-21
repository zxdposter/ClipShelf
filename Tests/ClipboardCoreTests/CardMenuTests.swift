import Foundation
import AppKit
import Testing
@testable import ClipboardCore
@testable import ClipShelf

struct CardMenuTests {
    private func text(_ value: String) -> Clip {
        Clip(kind: .text, text: value, sourceName: "Test", sourceBundle: "test",
             items: [[Representation(type: "public.utf8-plain-text", data: Data(value.utf8))]], identity: Data(value.utf8))
    }
    @Test func renameIsSearchablePersistentAndSurvivesRecopy() throws {
        var history = History()
        let clip = text("first")
        try history.insert(clip)
        try history.rename(id: clip.id, title: "常用片段")
        try history.insert(text("first"))
        #expect(history.clips.first?.title == "常用片段")
        #expect(history.clips.first?.matches("常用") == true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        try history.save(to: url)
        #expect(try History.load(from: url).clips.first?.title == "常用片段")
        try history.rename(id: clip.id, title: " ")
        #expect(history.clips.first?.title == nil)
    }
    @Test func editingMergesDuplicateWithoutLosingPinnedMemberships() throws {
        var history = History()
        let first = text("first"), second = text("second")
        try history.insert(first); try history.insert(second)
        let board = try history.addBoard(name: "Test", color: 1)
        history.addToBoard(clipID: first.id, boardID: board)
        history.addToBoard(clipID: second.id, boardID: board)
        try history.rename(id: first.id, title: "自定义")
        try history.editText(id: first.id, text: "second")
        #expect(history.clips.count == 1)
        #expect(history.clips.first?.id == first.id)
        #expect(history.clips.first?.title == "自定义")
        #expect(history.boards.last?.clipIDs == [first.id])
        #expect(history.clips.first?.items.first?.first?.data == Data("second".utf8))
    }
    @Test @MainActor func plainCopyAndContextTargetsAreIndependentFromPaste() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: isolatedPreferences())
        let first = text("first"), second = text("second")
        model.history = History(clips: [first, second]); model.resetSelection()
        #expect(model.targets(for: second).map(\.id) == [second.id])
        model.selection.selectAll(in: model.visible.map(\.id))
        #expect(model.targets(for: first).count == 2)
        #expect(model.copy(model.targets(for: first), plainText: true))
        #expect(board.string(forType: .string) == "first\nsecond")
        #expect(model.selection.ids.count == 2)
        #expect(safeLinkURL(text("file:///private/tmp/test")) == nil)
        #expect(sharingItems([first]).first as? String == "first")
    }
}
