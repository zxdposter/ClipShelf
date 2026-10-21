import Foundation
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
        await index.synchronize([SearchDocument(long)])
        #expect(try await index.search("尾部needle 特别 来源") == [long.id])
        #expect(try await index.search("不存在").isEmpty)
        await index.synchronize([])
        #expect(try await index.search("needle").isEmpty)
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
    private var continuation: CheckedContinuation<Set<UUID>, Never>?
    init(old: UUID, new: UUID) { self.old = old; self.new = new }
    func synchronize(_ documents: [SearchDocument]) {}
    func search(_ query: String) async -> Set<UUID> {
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
