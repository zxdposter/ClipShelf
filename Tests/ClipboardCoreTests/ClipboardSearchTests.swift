import Foundation
import AppKit
import Testing
import Combine
import Vision
@testable import ClipboardCore
@testable import ClipShelf

struct ClipboardSearchTests {
    private func image(_ byte: UInt8) -> Clip {
        let data = Data([byte])
        return Clip(kind: .image, text: "图片", sourceName: "截图", sourceBundle: "test.image",
                    items: [[Representation(type: "public.png", data: data)]], identity: data)
    }

    @Test @MainActor func appleOCRRecognizesChineseAndEnglishLocally() async throws {
        let image = NSImage(size: NSSize(width: 1000, height: 220))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 220).fill()
        ("中文搜索测试 Invoice 2026" as NSString).draw(at: NSPoint(x: 35, y: 90), withAttributes: [
            .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = Clip(kind: .image, text: "图片", sourceName: "Test", sourceBundle: "",
                        items: [[Representation(type: "public.tiff", data: tiff)]], identity: tiff)
        let service = ImageTextService(cacheURL: directory.appendingPathComponent("ocr.sqlite"))
        let recognized = try await service.text(for: clip)
        #expect(recognized.text.contains("中文"))
        #expect(recognized.text.localizedCaseInsensitiveContains("Invoice"))
        for query in ["中文", "zhongwen", "zw", "invoice"] {
            let boxes = recognized.matchingRegions(query)
            #expect(!boxes.isEmpty)
            #expect(boxes.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0) })
        }
        #expect(recognized.matchingRegions("").isEmpty)
        #expect(recognized.matchingRegions("not-in-picture").isEmpty)
        let reloaded = try await ImageTextService(cacheURL: directory.appendingPathComponent("ocr.sqlite"), recognize: { _ in throw CocoaError(.featureUnsupported) }).text(for: clip)
        #expect(reloaded == recognized)
        let index = MemorySearchIndex()
        try await index.synchronize([SearchDocument(clip, imageText: recognized)])
        for query in ["中文", "zhongwen", "zw", "中文 invoice", "zhong wen"] {
            #expect(try await index.search(query) == [clip.id], "query: \(query)")
        }
        let preferences = isolatedPreferences(); preferences.retention = .forever
        let board = NSPasteboard(name: .init("ClipShelf-OCR-highlight-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: preferences,
                                   imageTextService: service)
        model.history = History(clips: [clip])
        await model.waitForImageText()
        model.query = "中文"; await model.waitForSearch()
        let chineseBoxes = model.imageTextHighlights(for: clip)
        #expect(!chineseBoxes.isEmpty)
        model.query = "invoice"; await model.waitForSearch()
        #expect(!model.imageTextHighlights(for: clip).isEmpty)
        #expect(model.imageTextHighlights(for: clip) != chineseBoxes)
        model.query = ""; await model.waitForSearch()
        #expect(model.imageTextHighlights(for: clip).isEmpty)
        #expect(await model.finishPendingStorage())
    }

    @Test @MainActor func storedImageHistoryIsBackfilledAndReusesCacheAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.plist")
        let cacheURL = historyURL.appendingPathExtension("ocr.sqlite")
        let original = image(1)
        let history = History(clips: [original])
        try history.save(to: historyURL)
        let bytesBefore = try Data(contentsOf: historyURL)
        let board = NSPasteboard(name: .init("ClipShelf-OCR-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let preferences = isolatedPreferences(); preferences.retention = .forever
        let counter = ImageRecognitionProbe(blocked: false)
        let service = ImageTextService(cacheURL: cacheURL, recognize: { counter.recognize($0) })
        let model = ClipboardModel(pasteboard: board, storageURL: historyURL, preferences: preferences, imageTextService: service)
        await model.waitForImageText()
        model.query = "中文搜索"; await model.waitForSearch()
        #expect(model.visible.map(\.id) == [original.id])
        #expect(model.history.clips == history.clips)
        #expect(try Data(contentsOf: historyURL) == bytesBefore)
        #expect(await model.finishPendingStorage())
        let restoredService = ImageTextService(cacheURL: cacheURL, recognize: { _ in throw CocoaError(.featureUnsupported) })
        let restored = ClipboardModel(pasteboard: board, storageURL: historyURL, preferences: preferences, imageTextService: restoredService)
        await restored.waitForImageText()
        restored.query = "zwss"; await restored.waitForSearch()
        #expect(restored.visible.map(\.id) == [original.id])
        #expect(restored.imageTextError == nil && counter.calls == 1)
        #expect(await restored.finishPendingStorage())
    }

    @Test func cancelledOrFailedRecognitionCannotPoisonTheCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ocr.sqlite")
        let picture = image(1)
        let service = ImageTextService(cacheURL: url, recognize: { _ in throw CocoaError(.fileReadCorruptFile) })
        await #expect(throws: (any Error).self) { try await service.text(for: picture) }
        #expect(try await service.cachedTexts().isEmpty)
        let counter = ImageRecognitionProbe(blocked: false)
        let resumed = ImageTextService(cacheURL: url, recognize: { counter.recognize($0) })
        resumed.cancelRecognition()
        await #expect(throws: CancellationError.self) { try await resumed.text(for: picture) }
        #expect(counter.calls == 0)
        resumed.resumeRecognition()
        #expect(!(try await resumed.text(for: picture)).text.isEmpty)
        #expect(counter.calls == 1)
    }

    @Test func imageTextCachePersistsEmptyResultsAndPrunesDeletedImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ocr.sqlite")
        let counter = ImageRecognitionProbe(blocked: false)
        let service = ImageTextService(cacheURL: url, recognize: { counter.recognize($0) })
        let first = image(1), blank = image(0)
        let result = try await service.text(for: first)
        #expect(!result.text.isEmpty)
        #expect(try await service.text(for: blank).text.isEmpty)
        let restored = ImageTextService(cacheURL: url, recognize: { _ in throw CocoaError(.featureUnsupported) })
        #expect(try await restored.text(for: first) == result)
        #expect(try await restored.text(for: blank).text.isEmpty)
        #expect(counter.calls == 2 && counter.offMain)
        try await service.prune(keeping: [first.fingerprint])
        #expect(try await service.cachedTexts().keys.sorted() == [first.fingerprint])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test @MainActor func existingImagesAreBackfilledWithoutInvalidatingCardsOrSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ImageRecognitionProbe(blocked: true)
        defer { counter.release() }
        let service = ImageTextService(cacheURL: directory.appendingPathComponent("ocr.sqlite"), recognize: { counter.recognize($0) })
        let picture = image(1), other = clip("ordinary text")
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), imageTextService: service)
        model.history = History(clips: [picture, other])
        model.resetSelection()
        await model.waitForIndex()
        try await counter.waitForCalls(1)
        model.moveSelection(1)
        model.previewID = other.id
        let scroll = model.selectionScrollID
        var invalidations = 0
        let observation = model.objectWillChange.sink { invalidations += 1 }
        counter.release()
        await model.waitForImageText()
        withExtendedLifetime(observation) {}
        #expect(invalidations == 0)
        #expect(model.history.clips == [picture, other])
        #expect(model.selectedID == other.id && model.previewID == other.id)
        #expect(model.selectionScrollID == scroll)
        #expect(counter.calls == 1 && counter.offMain && counter.maximumActive == 1)
        for query in ["中文搜索", "zhongwensousuo", "zwss", "中文 invoice"] {
            model.query = query; await model.waitForSearch()
            #expect(model.visible.map(\.id) == [picture.id])
        }
    }

    @Test @MainActor func imageTextAddsMatchesWithoutResettingCurrentSearchFocus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ImageRecognitionProbe(blocked: true)
        defer { counter.release() }
        let service = ImageTextService(cacheURL: directory.appendingPathComponent("ocr.sqlite"), recognize: { counter.recognize($0) })
        let picture = image(1), other = clip("中文搜索")
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), imageTextService: service)
        model.history = History(clips: [picture, other])
        try await counter.waitForCalls(1)
        model.query = "中文搜索"; await model.waitForSearch()
        #expect(model.visible.map(\.id) == [other.id])
        model.previewID = other.id
        counter.release()
        await model.waitForImageText()
        #expect(model.visible.map(\.id) == [picture.id, other.id])
        #expect(model.selectedID == other.id && model.previewID == other.id)
        #expect(!model.searchPending)
    }

    @Test @MainActor func deletedOrEditedImagesCannotReceiveStaleOCRResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ImageRecognitionProbe(blocked: true)
        defer { counter.release() }
        let service = ImageTextService(cacheURL: directory.appendingPathComponent("ocr.sqlite"), recognize: { counter.recognize($0) })
        let original = image(1)
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), imageTextService: service)
        model.history = History(clips: [original])
        try await counter.waitForCalls(1)
        try model.history.editImage(id: original.id, png: Data([2]))
        let edited = try #require(model.history.clips.first)
        counter.release()
        await model.waitForImageText()
        model.query = "中文搜索"; await model.waitForSearch()
        #expect(model.visible.isEmpty)
        model.query = "新图片"; await model.waitForSearch()
        #expect(model.visible.map(\.id) == [original.id])
        #expect(counter.calls == 2 && counter.maximumActive == 1)
        #expect(try await service.cachedTexts().keys.sorted() == [edited.fingerprint])
        model.remove(edited)
        await model.waitForImageText()
        #expect(model.history.clips.isEmpty)
        #expect(try await service.cachedTexts().isEmpty)
    }

    @Test @MainActor func chineseCompositionDefersImageBackfill() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ImageRecognitionProbe(blocked: false)
        let service = ImageTextService(cacheURL: directory.appendingPathComponent("ocr.sqlite"), recognize: { counter.recognize($0) })
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), imageTextService: service)
        let field = ComposingImageSearchField()
        model.searchField = field
        model.history = History(clips: [image(1)])
        try await Task.sleep(for: .milliseconds(650))
        #expect(counter.calls == 0)
        field.editor.composing = false
        await model.waitForImageText()
        #expect(counter.calls == 1)
    }

    @Test @MainActor func interruptedOCRRetriesAfterInteractionInsteadOfMarkingTheImageFailed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ImageRecognitionProbe(blocked: false)
        let service = ImageTextService(cacheURL: directory.appendingPathComponent("ocr.sqlite"), recognize: {
            let text = counter.recognize($0)
            if counter.calls == 1 { throw NSError(domain: VNErrorDomain, code: VNErrorCode.requestCancelled.rawValue) }
            return text
        })
        let picture = image(1)
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), imageTextService: service)
        model.history = History(clips: [picture])
        await model.waitForImageText()
        #expect(counter.calls == 2 && model.imageTextError == nil)
        model.query = "中文搜索"; await model.waitForSearch()
        #expect(model.visible.map(\.id) == [picture.id])
    }

    private func clip(_ text: String, title: String? = nil) -> Clip {
        var clip = Clip(kind: .text, text: text, sourceName: "测试来源", sourceBundle: "", items: [], identity: Data(text.utf8))
        clip.title = title
        return clip
    }
    @Test func chunksCoverUnicodeAndBoundaryTermsWithoutDroppingTheTail() {
        let text = String(repeating: "甲", count: 4999) + "边界你好" + String(repeating: "😀", count: 6000) + "尾部关键词"
        let chunks = SpotlightSearchIndex.chunks(text)
        #expect(chunks.allSatisfy { $0.count <= 5000 })
        #expect(chunks.contains { $0.contains("边界你好") })
        #expect(chunks.last?.hasSuffix("尾部关键词") == true)
        #expect(SpotlightSearchIndex.escape("\\\"*?") == "\\\\\\\"\\*\\?")
    }
    @Test func cardPreviewIsBoundedButSearchAndFullPreviewKeepTheTail() {
        let text = String(repeating: "甲", count: 50000) + "尾部关键词"
        let item = clip(text)
        #expect(cardClipText(item).characters.count == 1200)
        #expect(String(formattedClipText(item).characters).hasSuffix("尾部关键词"))
        #expect(item.text == text)
    }
    @Test func backgroundSearchPreservesTermsSourceTitleAndUpdates() async throws {
        let index = MemorySearchIndex()
        let long = clip(String(repeating: "长文本", count: 30000) + " 尾部needle", title: "特别标题")
        try await index.synchronize([SearchDocument(long)])
        #expect(try await index.search("尾部needle 特别 来源") == [long.id])
        #expect(try await index.search("不存在").isEmpty)
        try await index.synchronize([])
        #expect(try await index.search("needle").isEmpty)
    }
    @Test @MainActor func defaultSearchFindsLiteralTextLinksAndLongContent() async {
        let plain = clip("claude-mem")
        let link = clip("https://github.com/thedotmack/claude-mem")
        let long = clip(String(repeating: "正文", count: 30000) + " CLAUDE-MEM", title: "历史记录")
        let punctuation = clip("路径 /tmp/a_b.swift?value=* 中文片段")
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.history = History(clips: [plain, link, long, punctuation])
        await model.waitForIndex()
        for query in ["claude-mem", "CLAUDE-MEM", "aude-me"] {
            model.query = query
            await model.waitForSearch()
            #expect(Set(model.visible.map(\.id)) == [plain.id, link.id, long.id])
        }
        model.query = "历史记录 claude-mem 来源"
        await model.waitForSearch()
        #expect(model.visible.map(\.id) == [long.id])
        model.query = "/tmp/a_b.swift?value=* 中文片段"
        await model.waitForSearch()
        #expect(model.visible.map(\.id) == [punctuation.id])
    }
    @Test @MainActor func sourceFiltersUseAppIdentityAndCombineWithTextTypeAndPinboards() async throws {
        let first = Clip(kind: .text, text: "invoice one", sourceName: "Browser", sourceBundle: "app.one", items: [], identity: Data("one".utf8))
        let second = Clip(kind: .text, text: "invoice two", sourceName: "Browser", sourceBundle: "app.two", items: [], identity: Data("two".utf8))
        let link = Clip(kind: .link, text: "https://example.com/invoice", sourceName: "Browser", sourceBundle: "app.one", items: [], identity: Data("link".utf8))
        let other = clip("not an invoice")
        let index = DelayedIndex(old: first.id, new: second.id)
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), searchIndex: index)
        model.history = History(clips: [first, second, link, other])
        await model.waitForIndex()
        #expect(model.sourceApps.count == 3)
        let app = try #require(model.sourceApps.first { $0.bundle == "app.one" })
        let another = try #require(model.sourceApps.first { $0.bundle == "app.two" })
        model.toggleSourceApp(app)
        #expect(model.visible.map(\.id) == [first.id, link.id])
        model.toggleSourceApp(another)
        #expect(model.visible.map(\.id) == [first.id, second.id, link.id])
        #expect(await index.queries.isEmpty)
        model.filter = .link
        #expect(model.visible.map(\.id) == [link.id])
        let board = try model.history.addBoard(name: "Work", color: 0)
        model.history.addToBoard(clipID: second.id, boardID: board)
        model.history.addToBoard(clipID: link.id, boardID: board)
        model.selectBoard(board)
        #expect(model.visible.map(\.id) == [link.id])
        model.filter = nil
        await model.waitForIndex()
        model.query = "invoice two"
        await model.waitForSearch()
        #expect(model.visible.map(\.id) == [second.id])
        model.clearSearch()
        #expect(model.selectedSourceIDs.isEmpty)
        #expect(model.filter == nil)
        #expect(model.visible.map(\.id) == [link.id, second.id])
        model.selectedSourceIDs = ["bundle:missing"]
        #expect(model.visible.isEmpty)
    }
    @Test @MainActor func sourceSuggestionsConsumeOnlyAppTextAndKeepOtherTerms() throws {
        let chrome = Clip(kind: .text, text: "sample", sourceName: "Google Chrome", sourceBundle: "com.google.Chrome", items: [], identity: Data())
        let wechat = Clip(kind: .text, text: "消息", sourceName: "微信", sourceBundle: "com.tencent.xinWeChat", items: [], identity: Data())
        let fallback = Clip(kind: .text, text: "sample", sourceName: "Legacy App", sourceBundle: "", items: [], identity: Data())
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.history = History(clips: [chrome, wechat, fallback])
        model.searchFocused = true
        model.query = "invoice Google Chrome"
        let app = try #require(model.suggestedSourceApps.first)
        model.selectSourceSuggestion(app)
        #expect(model.query == "invoice")
        #expect(model.selectedSourceApps.map(\.bundle) == ["com.google.Chrome"])
        model.query = "weixin"
        #expect(model.suggestedSourceApps.map(\.name) == ["微信"])
        #expect(model.moveSourceSuggestion(1))
        model.submitSearch()
        #expect(model.query.isEmpty)
        #expect(model.selectedSourceIDs.count == 2)
        model.query = "Legacy"
        #expect(model.suggestedSourceApps.map(\.id) == ["name:Legacy App"])
        model.searchFocused = false
        #expect(model.suggestedSourceApps.isEmpty)
        model.history = History(clips: [fallback])
        #expect(model.selectedSourceIDs.count == 2)
        #expect(model.visible.isEmpty)
        model.clearSearch()
        #expect(model.selectedSourceIDs.isEmpty)
        #expect(model.sourceApps.map(\.id) == ["name:Legacy App"])
    }
    @Test func normalizedSearchPreservesAccentsWidthAndLiteralPunctuation() async throws {
        let item = clip("Café ＡＢＣ ﬁle Straße /tmp/a_b.swift?value=*")
        let index = MemorySearchIndex()
        try await index.synchronize([SearchDocument(item)])
        for query in ["cafe", "abc", "file", "STRASSE", "/tmp/a_b.swift?value=*"] {
            #expect(try await index.search(query) == [item.id], "query: \(query)")
        }
    }
    @Test @MainActor func searchRemainsAvailableWhileTheFirstIndexIsBuilding() async throws {
        let index = BuildingIndex()
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), searchIndex: index)
        let target = try #require(model.history.clips.first)
        model.query = String(target.text.prefix(4))
        await model.waitForSearch()
        #expect(model.visible.contains { $0.id == target.id })
        await index.finishBuilding()
        await model.waitForIndex()
    }
    @Test @MainActor func pinyinSearchFindsChineseTextTitlesAndSources() async throws {
        _ = NSApplication.shared
        let text = clip("中文搜索，支持剪贴板")
        let title = clip("project notes", title: "项目计划")
        let mixed = clip("微信Mac 版本")
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.history = History(clips: [text, title, mixed])
        await model.waitForIndex()
        for query in ["zhongwen", "ZHONGWEN", "zhōngwén", "zwss", "jiantieban", "jtb", "zhong wen", "中文 jtb"] {
            model.query = query
            await model.waitForSearch()
            #expect(model.visible.map(\.id) == [text.id], "query: \(query)")
        }
        for query in ["xiangmujihua", "xmjh", "project xmjh"] {
            model.query = query
            await model.waitForSearch()
            #expect(model.visible.map(\.id) == [title.id])
        }
        model.query = "weixinMac"
        await model.waitForSearch()
        #expect(model.visible.map(\.id) == [mixed.id])
        model.query = "ceshilaiyuan"
        await model.waitForSearch()
        #expect(model.visible.count == 3)
        model.beginRename(title); model.renameDraft = "会议纪要"; model.finishRename()
        model.query = "hyjy"
        await model.waitForSearch()
        #expect(model.visible.map(\.id) == [title.id])
        model.query = "xmjh"
        await model.waitForSearch()
        #expect(model.visible.isEmpty)
    }
    @Test @MainActor func rapidTypingIsDebouncedAndKeepsCardsUntilResultsArrive() async {
        let first = clip("old"), second = clip("new")
        let index = DelayedIndex(old: first.id, new: second.id)
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), searchIndex: index)
        model.history = History(clips: [first, second])
        await model.waitForIndex()
        for query in ["o", "ol", "old", "new"] { model.query = query }
        #expect(model.visible.map(\.id) == [first.id, second.id])
        await model.waitForSearch()
        #expect(await index.queries == ["new"])
        #expect(model.visible.map(\.id) == [second.id])
        model.query = "new "
        await model.waitForSearch()
        #expect(await index.queries == ["new"])
        model.query = "old"
        await index.waitForOld()
        #expect(model.searchPending)
        #expect(model.visible.map(\.id) == [second.id])
        let waiting = Task { await model.waitForSearch() }
        await Task.yield()
        model.query = "new"
        await index.finishOld()
        await waiting.value
        #expect(!model.searchPending)
        #expect(model.visible.map(\.id) == [second.id])
        model.clearSearch()
        #expect(model.visible.map(\.id) == [first.id, second.id])
    }
    @Test @MainActor func lateQueriesCannotReplaceNewResultsAndClearCancelsPendingSearch() async {
        let first = clip("old"), second = clip("new")
        let index = DelayedIndex(old: first.id, new: second.id)
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), searchIndex: index)
        model.history = History(clips: [first, second])
        await model.waitForIndex()
        model.query = "old"
        await index.waitForOld()
        model.query = "new"
        await model.waitForSearch()
        #expect(model.visible.map(\.id) == [second.id])
        await index.finishOld()
        await Task.yield()
        #expect(model.visible.map(\.id) == [second.id])
        model.query = "old"
        await index.waitForOld()
        model.clearSearch()
        await index.finishOld()
        await Task.yield()
        #expect(model.searchMatches.isEmpty)
        #expect(!model.searchPending)
        #expect(model.visible.count == 2)
    }
    @Test @MainActor func historyUpdatesReindexAndFailuresFallBackOffTheMainActor() async {
        _ = NSApplication.shared
        let item = clip("content", title: "before")
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences(), searchIndex: FailingIndex())
        model.history = History(clips: [item])
        model.query = "before"
        await model.waitForSearch()
        #expect(model.visible.map(\.id) == [item.id])
        model.beginRename(item); model.renameDraft = "after"; model.finishRename()
        await model.waitForSearch()
        #expect(model.visible.isEmpty)
        model.query = "after"
        await model.waitForSearch()
        #expect(model.visible.map(\.id) == [item.id])
        model.remove(item)
        await model.waitForSearch()
        #expect(model.visible.isEmpty)
        model.undoDeletion()
        await model.waitForSearch()
        #expect(model.visible.map(\.id) == [item.id])
    }
}

private final class ImageRecognitionProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked: Bool
    private var count = 0
    private var active = 0
    private var peak = 0
    private var background = true
    init(blocked: Bool) { self.blocked = blocked }
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    var maximumActive: Int { condition.lock(); defer { condition.unlock() }; return peak }
    var offMain: Bool { condition.lock(); defer { condition.unlock() }; return background }
    func recognize(_ data: Data) -> String {
        condition.lock()
        count += 1; active += 1; peak = max(peak, active); background = background && !Thread.isMainThread
        while blocked { condition.wait() }
        active -= 1; condition.unlock()
        if data.first == 0 { return "" }
        return data.first == 2 ? "新图片" : "中文搜索 Invoice 2026"
    }
    func release() { condition.lock(); blocked = false; condition.broadcast(); condition.unlock() }
    func waitForCalls(_ expected: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while calls < expected {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderReadCorrupt) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor private final class ComposingImageSearchField: NSTextField {
    final class Editor: NSTextView {
        var composing = true
        override func hasMarkedText() -> Bool { composing }
    }
    let editor = Editor()
    override func currentEditor() -> NSText? { editor }
}

private actor FailingIndex: ClipboardSearchIndex {
    func synchronize(_ documents: [SearchDocument]) throws { throw CocoaError(.fileReadUnknown) }
    func search(_ query: String) throws -> Set<UUID> { throw CocoaError(.fileReadUnknown) }
}
private actor DelayedIndex: ClipboardSearchIndex {
    let old: UUID
    let new: UUID
    private(set) var queries: [String] = []
    private var continuation: CheckedContinuation<Set<UUID>, Never>?
    init(old: UUID, new: UUID) { self.old = old; self.new = new }
    func synchronize(_ documents: [SearchDocument]) {}
    func search(_ query: String) async -> Set<UUID> {
        queries.append(query)
        if query == "old" { return await withCheckedContinuation { continuation = $0 } }
        return [new]
    }
    func waitForOld() async { while continuation == nil { await Task.yield() } }
    func finishOld() { continuation?.resume(returning: [old]); continuation = nil }
}

private actor BuildingIndex: ClipboardSearchIndex {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func synchronize(_ documents: [SearchDocument]) async {
        if !released { await withCheckedContinuation { continuations.append($0) } }
    }
    func search(_ query: String) -> Set<UUID> { [] }
    func finishBuilding() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}
