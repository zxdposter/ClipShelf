import Foundation
import AppKit
import SwiftUI
import Testing
@testable import ClipboardCore
@testable import ClipShelf

struct PinboardTests {
    private func clip(_ text: String) -> Clip {
        Clip(kind: .text, text: text, sourceName: "test", sourceBundle: "",
             items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]], identity: Data(text.utf8))
    }
    @Test func migrationMembershipDedupAndPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = clip("pinned")
        try PropertyListEncoder().encode([first]).write(to: url)
        var history = try History.load(from: url)
        #expect(history.clips == [first])
        #expect(history.boards.first?.name == "实用链接")
        let board = try history.addBoard(name: "项目", color: 2)
        history.addToBoard(clipID: first.id, boardID: board)
        history.addToBoard(clipID: first.id, boardID: board)
        try history.insert(clip("pinned"))
        #expect(history.boards.last?.clipIDs == [first.id])
        for index in 0..<History.maximumItems { try history.insert(clip("new \(index)")) }
        #expect(history.clips.contains(where: { $0.id == first.id }))
        try history.editBoard(id: board, name: "资料", color: 4)
        try history.save(to: url)
        let restored = try History.load(from: url)
        #expect(restored.boards == history.boards)
        #expect(restored.clips == history.clips)
        history.removeBoard(id: board)
        #expect(history.clips.contains(where: { $0.id == first.id }))
    }
    @Test func boardValidationReorderAndRemoval() throws {
        var history = History()
        let first = clip("a"); try history.insert(first)
        let a = try history.addBoard(name: "A", color: 0)
        let b = try history.addBoard(name: "B", color: 1)
        #expect(throws: HistoryError.self) { try history.addBoard(name: "   ", color: 0) }
        #expect(throws: HistoryError.self) { try history.editBoard(id: a, name: "invalid", color: 6) }
        history.addToBoard(clipID: UUID(), boardID: a)
        history.addToBoard(clipID: first.id, boardID: a)
        history.moveBoard(id: b, before: a)
        #expect(history.boards.firstIndex(where: { $0.id == b })! < history.boards.firstIndex(where: { $0.id == a })!)
        history.removeFromBoard(clipID: first.id, boardID: a)
        #expect(history.clips.count == 1)
        history.addToBoard(clipID: first.id, boardID: a)
        history.remove(id: first.id)
        #expect(history.boards.allSatisfy { $0.clipIDs.isEmpty })
    }
    @Test @MainActor func boardFilteringAndEditingUseSamePersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let model = ClipboardModel(pasteboard: board, storageURL: url, preferences: isolatedPreferences())
        board.setString("searchable", forType: .string)
        model.capture(expectedChange: board.changeCount)
        let item = try #require(model.history.clips.first)
        model.beginBoardEdit(); model.boardNameDraft = "工作"; model.finishBoardEdit()
        let group = try #require(model.history.boards.last)
        #expect(model.visible.isEmpty)
        #expect(model.drop(["clip:\(item.id)"], on: group))
        #expect(model.visible.map(\.id) == [item.id])
        model.query = "missing"; await model.waitForSearch(); #expect(model.visible.isEmpty)
        model.query = "search"; await model.waitForSearch(); #expect(model.visible.count == 1)
        model.removeFromCurrentBoard(item); await model.waitForSearch(); #expect(model.visible.isEmpty)
        model.selectBoard(nil); #expect(model.visible.count == 1)
        #expect(try History.load(from: url).boards == model.history.boards)
    }
    @Test @MainActor func batchDropKeepsHistoryAndDeduplicatesMembership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let model = ClipboardModel(pasteboard: pasteboard, storageURL: url, preferences: isolatedPreferences())
        for text in ["first", "second"] {
            pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
            model.capture(expectedChange: pasteboard.changeCount)
        }
        let original = model.history.clips
        let board = try #require(model.history.boards.first)
        model.selection.selectAll(in: model.visible.map(\.id))
        let payload = model.dragPayload(for: try #require(original.first))
        model.dropTargetBoardID = board.id
        #expect(model.drop([payload], on: board))
        #expect(model.dropTargetBoardID == nil)
        #expect(model.message == nil)
        #expect(model.drop([payload], on: board))
        #expect(model.history.clips == original)
        #expect(model.history.boards.first?.clipIDs == original.map(\.id))
        #expect(try History.load(from: url).boards == model.history.boards)
        #expect(!model.drop(["clips:invalid"], on: board))
    }
    @Test @MainActor func richTextRetainsFontColorAndPlainFallback() throws {
        let source = NSAttributedString(string: "Styled", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.red,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rich = Clip(kind: .text, text: "Styled", sourceName: "test", sourceBundle: "",
                        items: [[Representation(type: "public.rtf", data: data)]], identity: Data("Styled".utf8))
        let rendered = NSAttributedString(formattedClipText(rich))
        #expect(rendered.string == "Styled")
        let font = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 22)
        let differentlyStyled = NSAttributedString(string: "Styled", attributes: [.font: NSFont.systemFont(ofSize: 9)])
        let otherData = try differentlyStyled.data(from: NSRange(location: 0, length: differentlyStyled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let other = Clip(kind: .text, text: "Styled", sourceName: "test", sourceBundle: "",
                         items: [[Representation(type: "public.rtf", data: otherData)]], identity: Data("Styled".utf8))
        let otherRendered = NSAttributedString(formattedClipText(other))
        #expect((otherRendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 9)
        #expect(NSAttributedString(formattedClipText(rich)).isEqual(to: rendered))
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
        #expect(String(formattedClipText(clip("plain")).characters) == "plain")
        let broken = Clip(kind: .text, text: "fallback", sourceName: "test", sourceBundle: "",
                          items: [[Representation(type: "public.rtf", data: Data([0]))]], identity: Data())
        #expect(String(formattedClipText(broken).characters) == "fallback")
    }
    @Test @MainActor func dropToCreateWaitsForNameAndCancellationDoesNotChangeHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let model = ClipboardModel(pasteboard: pasteboard, storageURL: url, preferences: isolatedPreferences())
        for text in ["first", "second"] {
            pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
            model.capture(expectedChange: pasteboard.changeCount)
        }
        let clips = model.history.clips
        let boards = model.history.boards
        #expect(!model.dropToNewBoard(["board:\(boards[0].id)", "clips:invalid"]))
        #expect(!model.namingDroppedBoard)
        model.selection.selectAll(in: model.visible.map(\.id))
        let payload = model.dragPayload(for: try #require(clips.first))
        #expect(model.dropToNewBoard([payload]))
        #expect(model.namingDroppedBoard && model.creatingBoard)
        #expect(model.history.boards == boards)
        model.cancelBoardEdit()
        #expect(model.history.boards == boards)
        #expect(!model.namingDroppedBoard && !model.creatingBoard)
        #expect(model.dropToNewBoard([payload, payload]))
        model.resetSelection()
        model.boardNameDraft = "拖入收藏"
        model.finishBoardEdit()
        #expect(model.history.boards.last?.clipIDs == clips.map(\.id))
        #expect(model.history.clips == clips)
        #expect(!model.namingDroppedBoard && !model.creatingBoard)
        #expect(try History.load(from: url).boards == model.history.boards)
    }
    @Test @MainActor func deletionUndoRestoresCardsAndMembershipWithoutLosingNewCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let model = ClipboardModel(pasteboard: pasteboard, storageURL: url, preferences: isolatedPreferences())
        for text in ["first", "second"] {
            pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
            model.capture(expectedChange: pasteboard.changeCount)
        }
        let original = model.history.clips
        let board = try #require(model.history.boards.first)
        model.selection.selectAll(in: model.visible.map(\.id))
        #expect(model.drop([model.dragPayload(for: original[0])], on: board))
        model.remove(original[0])
        #expect(model.history.clips.isEmpty)
        #expect(model.history.boards.first?.clipIDs.isEmpty == true)
        pasteboard.clearContents(); pasteboard.setString("new capture", forType: .string)
        model.capture(expectedChange: pasteboard.changeCount)
        model.undoDeletion()
        #expect(Set(model.history.clips.map(\.id)).isSuperset(of: original.map(\.id)))
        #expect(model.history.clips.contains { $0.text == "new capture" })
        #expect(model.history.boards.first?.clipIDs == original.map(\.id))
        #expect(try History.load(from: url).clips == model.history.clips)
        model.remove(original[0]); model.remove(original[1])
        model.undoDeletion(); model.undoDeletion()
        #expect(model.history.clips.count == 3)
    }
    @Test func undoMergesRecopiedContentAndRefusesCapacityOverflow() throws {
        let item = clip("again")
        var history = History(clips: [item])
        let board = try #require(history.boards.first)
        history.addToBoard(clipID: item.id, boardID: board.id)
        let deletion = history.deletion(for: [item.id])
        history.remove(id: item.id)
        let refreshed = clip("again"); try history.insert(refreshed)
        try history.restore(deletion)
        #expect(history.clips == [refreshed])
        #expect(history.boards.first?.clipIDs == [refreshed.id])
        history.remove(id: refreshed.id)
        for index in 0..<History.maximumItems { try history.insert(clip("item \(index)")) }
        let full = history.clips
        #expect(throws: HistoryError.self) { try history.restore(deletion) }
        #expect(history.clips == full)
    }
    @Test func panelGeometryStaysOnTargetScreenAndUsesShortReveal() {
        let secondary = NSRect(x: -1920, y: -500, width: 1920, height: 1080)
        let shown = ShelfGeometry.shown(in: secondary)
        #expect(shown.minX == -1904 && shown.minY == -484)
        #expect(shown.width == 1888 && shown.height == 352)
        #expect(ShelfGeometry.hidden(from: shown).minY == shown.minY - 18)
        let small = ShelfGeometry.shown(in: NSRect(x: 0, y: 0, width: 20, height: 20))
        #expect(small.width == 0 && small.height == 0)
    }
    @Test func fullPinboardsRejectNewCaptureWithoutDiscardingPinnedItems() throws {
        var history = History()
        let board = try #require(history.boards.first?.id)
        for index in 0..<History.maximumItems {
            let item = clip("pinned \(index)"); try history.insert(item)
            history.addToBoard(clipID: item.id, boardID: board)
        }
        let original = history.clips
        #expect(throws: HistoryError.self) { try history.insert(clip("new")) }
        #expect(history.clips == original)
        #expect(history.boards.first?.clipIDs.count == History.maximumItems)
    }
    @Test @MainActor func themeAccentIsReadableInBothAppearances() {
        func luminance(_ color: Color) -> Double {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let ink = luminance(ShelfDesign.accent), paper = luminance(ShelfDesign.paper)
                #expect((max(ink, paper) + 0.05) / (min(ink, paper) + 0.05) >= 4.5)
            }
        }
    }

}
