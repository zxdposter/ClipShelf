import Foundation
import AppKit
import Testing
@testable import ClipboardCore
@testable import ClipShelf

struct ClipboardSearchTests {
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
