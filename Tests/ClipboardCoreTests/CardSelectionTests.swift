import Foundation
import AppKit
import Testing
@testable import ClipboardCore
@testable import ClipShelf

struct CardSelectionTests {
    @Test func commandClickTogglesAndPlainClickReplaces() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = CardSelection()
        selection.reset(in: ids)
        selection.select(ids[2], in: ids, command: true)
        #expect(selection.ids == [ids[0], ids[2]])
        selection.select(ids[0], in: ids, command: true)
        #expect(selection.ids == [ids[2]])
        selection.select(ids[2], in: ids, command: true)
        #expect(selection.ids.isEmpty)
        selection.select(ids[4], in: ids)
        #expect(selection.ids == [ids[4]])
    }
    @Test func shiftUsesAnchorAndCommandShiftAddsRange() {
        let ids = (0..<7).map { _ in UUID() }
        var selection = CardSelection()
        selection.select(ids[2], in: ids)
        selection.select(ids[5], in: ids, shift: true)
        #expect(selection.ids == Set(ids[2...5]))
        selection.select(ids[3], in: ids, shift: true)
        #expect(selection.ids == Set(ids[2...3]))
        selection.select(ids[0], in: ids, command: true)
        selection.select(ids[1], in: ids, command: true, shift: true)
        #expect(selection.ids == Set(ids[0...3]))
        selection.move(1, in: ids, extending: false)
        #expect(selection.ids == [ids[2]])
        selection.move(1, in: ids, extending: true)
        #expect(selection.ids == Set(ids[2...3]))
    }
    @Test func selectAllOnlyIncludesCurrentResultsAndEmptyResetIsSafe() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = CardSelection()
        selection.select(ids[1], in: ids)
        selection.selectAll(in: ids)
        #expect(selection.ids == Set(ids))
        #expect(selection.focusedID == ids[1])
        selection.reset(in: Array(ids[2...3]))
        selection.selectAll(in: Array(ids[2...3]))
        #expect(selection.ids == Set(ids[2...3]))
        selection.reset(in: [])
        selection.move(1, in: [], extending: true)
        #expect(selection.ids.isEmpty && selection.focusedID == nil)
        selection.select(UUID(), in: ids)
        #expect(selection.ids.isEmpty)
    }
    @Test @MainActor func multipleSelectionCopiesInDisplayOrderAndCanBeGroupedTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: isolatedPreferences())
        for text in ["first", "second", "third"] {
            board.clearContents(); board.setString(text, forType: .string)
            model.capture(expectedChange: board.changeCount)
        }
        model.resetSelection(); model.selection.selectAll(in: model.visible.map(\.id))
        #expect(model.copy(model.selectedClips))
        #expect(board.string(forType: .string) == "third\nsecond\nfirst")
        let item = try #require(model.visible.first)
        model.beginBoardEdit(clip: item); model.boardNameDraft = "全部收藏"; model.finishBoardEdit()
        #expect(model.visible.count == 3)
        #expect(model.history.boards.last?.clipIDs == model.visible.map(\.id))
        let pinned = try #require(model.history.boards.last)
        model.removeFromCurrentBoard(item)
        #expect(model.visible.count == 2)
        model.selectBoard(nil); model.selection.selectAll(in: model.visible.map(\.id))
        #expect(model.drop([model.dragPayload(for: item)], on: pinned))
        #expect(model.history.boards.last?.clipIDs.count == 3)
    }
}
