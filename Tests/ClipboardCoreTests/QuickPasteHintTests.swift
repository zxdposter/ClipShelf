import AppKit
import Testing
import SwiftUI
@testable import ClipShelf
@testable import ClipboardCore

struct QuickPasteHintTests {
    @Test @MainActor func keyboardScrollReachesNativeViewport() async throws {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.history = History(clips: (0..<200).map { index in
            Clip(kind: .text, text: String(index), sourceName: "Test", sourceBundle: "test", items: [], identity: Data(String(index).utf8))
        })
        model.resetSelection()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 352), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ShelfView(model: model, dismiss: {}, openSettings: {}, enableCapture: {}, paste: { _, _ in }))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        for _ in 0..<50 { model.moveSelection(1) }
        try await Task.sleep(for: .milliseconds(150))
        func findScrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(findScrolls)
        }
        let scroll = try #require(findScrolls(window.contentView!).first { ($0.documentView?.frame.width ?? 0) > 10000 })
        #expect(scroll.contentView.bounds.minX > 12000)
        let index = try #require(model.visible.firstIndex { $0.id == model.selectedID })
        let left = ShelfCardLayout.inset + CGFloat(index) * (ShelfCardLayout.width + ShelfCardLayout.spacing)
        #expect(left >= scroll.contentView.bounds.minX)
        #expect(left + ShelfCardLayout.width <= scroll.contentView.bounds.maxX)
    }
    @Test func keyboardScrollOnlyMovesCardsOutsideTheViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 300)
        #expect(ShelfCardLayout.navigationOffset(index: 0, count: 200, viewport: viewport) == 0)
        #expect(ShelfCardLayout.navigationOffset(index: 2, count: 200, viewport: viewport) == 0)
        #expect(ShelfCardLayout.navigationOffset(index: 3, count: 200, viewport: viewport) == 120)
        let scrolled = CGRect(x: 120, y: 0, width: 1000, height: 300)
        #expect(ShelfCardLayout.navigationOffset(index: 3, count: 200, viewport: scrolled) == 120)
        #expect(ShelfCardLayout.navigationOffset(index: 0, count: 200, viewport: scrolled) == 0)
        #expect(ShelfCardLayout.navigationOffset(index: 199, count: 200, viewport: viewport) == 53432)
        #expect(ShelfCardLayout.navigationOffset(index: 0, count: 1, viewport: scrolled) == 0)
        #expect(ShelfCardLayout.navigationOffset(index: 0, count: 0, viewport: scrolled) == 120)
        #expect(ShelfCardLayout.navigationOffset(index: -1, count: 200, viewport: scrolled) == 120)
        #expect(ShelfCardLayout.navigationOffset(index: 1, count: 200, viewport: CGRect(x: 0, y: 0, width: 200, height: 300)) == 272)
    }
    @Test @MainActor func keyboardNavigationInvalidatesOnlyChangedCardFaces() {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        let text = String(repeating: "long clipboard content ", count: 400)
        let clips = (0..<200).map { index in
            Clip(kind: .text, text: "\(index) \(text)", sourceName: "Test", sourceBundle: "test", items: [], identity: Data("\(index)".utf8))
        }
        model.history = History(clips: clips)
        model.resetSelection()
        func faces() -> [ClipCardFaceState] {
            clips.map { ClipCardFaceState(clip: $0, quickPasteNumber: nil, selected: model.selection.ids.contains($0.id), model: model, language: .chinese) }
        }
        var previous = faces()
        for _ in 0..<50 {
            model.moveSelection(1)
            let next = faces()
            #expect(zip(previous, next).filter { $0 != $1 }.count == 2)
            previous = next
        }
        #expect(model.selectedID == clips[50].id)
        model.renamingID = clips[0].id
        model.renameDraft = "renamed"
        let renaming = faces()
        #expect(previous[0] != renaming[0])
        #expect(previous[100] == renaming[100])
        model.renameDraft = "updated"
        #expect(renaming[0] != faces()[0])
    }
    @Test @MainActor func hintsTrackModifierAndVisibleOrder() async throws {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        #expect(model.quickPasteNumber(at: 0) == nil)
        model.updateQuickPasteModifier(.command)
        #expect(model.commandHeld)
        #expect(model.quickPasteNumber(at: 0) == 1)
        #expect(model.quickPasteClip(number: 1)?.id == model.visible.first?.id)
        model.query = "会议"
        await model.waitForSearch()
        #expect(model.quickPasteNumber(at: 0) == 1)
        #expect(model.quickPasteClip(number: 1)?.id == model.visible.first?.id)
        #expect(model.quickPasteClip(number: 2) == nil)
        model.updateQuickPasteModifier([])
        #expect(!model.commandHeld)
        #expect(model.quickPasteNumber(at: 0) == nil)
        model.preferences.quickPasteModifier = .option
        model.updateQuickPasteModifier(.command)
        #expect(model.commandHeld)
        #expect(model.quickPasteNumber(at: 0) == nil)
        model.updateQuickPasteModifier(.option)
        #expect(!model.commandHeld)
        #expect(model.quickPasteNumber(at: 0) == 1)
        model.creatingBoard = true
        #expect(model.quickPasteNumber(at: 0) == nil)
    }
    @Test @MainActor func pointerSelectionDoesNotRequestScrollAndKeyboardStillDoes() throws {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        let clips = model.visible
        model.selectClip(clips[0])
        model.selectClip(clips[1])
        #expect(model.selectedID == clips[1].id)
        #expect(model.selectionScrollID == nil)
        model.moveSelection(1)
        #expect(model.selectedID == clips[2].id)
        #expect(model.selectionScrollID == clips[2].id)
        model.moveSelection(-1)
        #expect(model.selectedID == clips[1].id)
        #expect(model.selectionScrollID == clips[1].id)
        model.moveSelection(1)
        model.selectClip(clips[1], modifiers: .command)
        #expect(model.selection.ids.contains(clips[1].id))
        #expect(model.selectionScrollID == nil)
        model.selectClip(clips[0])
        model.selectClip(clips[2], modifiers: .shift)
        #expect(model.selection.ids == Set(clips.prefix(3).map(\.id)))
        #expect(model.selectionScrollID == nil)
    }
    @Test @MainActor func hintsAndBindingsStopAtNine() {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        let clips = (0..<12).map { index in
            Clip(kind: .text, text: String(index), sourceName: "Test", sourceBundle: "test", items: [], identity: Data(String(index).utf8))
        }
        model.history = History(clips: clips)
        model.updateQuickPasteModifier(.command)
        #expect(model.quickPasteNumber(at: 8) == 9)
        #expect(model.quickPasteNumber(at: 9) == nil)
        #expect(model.quickPasteNumber(at: -1) == nil)
        #expect(model.quickPasteClip(number: 9)?.id == clips[8].id)
        #expect(model.quickPasteClip(number: 10) == nil)
        #expect(model.quickPasteClip(number: 0) == nil)
    }
}

struct DirectPastePermissionTests {
    @Test @MainActor func permissionPromptExplainsFallbackAndRequiresAnExplicitChoice() {
        let alert = directPastePermissionAlert()
        #expect(alert.buttons.map(\.title) == ["打开系统设置", "稍后"])
        #expect(alert.informativeText.contains("内容已复制"))
        #expect(alert.informativeText.contains("/Applications/ClipShelf.app"))
    }
}
