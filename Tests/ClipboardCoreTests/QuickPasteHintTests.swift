import AppKit
import Testing
@testable import ClipShelf
@testable import ClipboardCore

struct QuickPasteHintTests {
    @Test @MainActor func hintsTrackModifierAndVisibleOrder() async throws {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        #expect(model.quickPasteNumber(at: 0) == nil)
        model.updateQuickPasteModifier(.command)
        #expect(model.quickPasteNumber(at: 0) == 1)
        #expect(model.quickPasteClip(number: 1)?.id == model.visible.first?.id)
        model.query = "会议"
        await model.waitForSearch()
        #expect(model.quickPasteNumber(at: 0) == 1)
        #expect(model.quickPasteClip(number: 1)?.id == model.visible.first?.id)
        #expect(model.quickPasteClip(number: 2) == nil)
        model.updateQuickPasteModifier([])
        #expect(model.quickPasteNumber(at: 0) == nil)
        model.preferences.quickPasteModifier = .option
        model.updateQuickPasteModifier(.command)
        #expect(model.quickPasteNumber(at: 0) == nil)
        model.updateQuickPasteModifier(.option)
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
