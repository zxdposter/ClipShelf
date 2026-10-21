import Foundation
import Testing
@testable import ClipboardCore

struct HistoryTests {
    private func clip(_ text: String, source: String = "备忘录", kind: ClipKind = .text, date: Date = Date()) -> Clip {
        Clip(kind: kind, text: text, sourceName: source, sourceBundle: "test.app",
             items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]],
             identity: Data(text.utf8), copiedAt: date)
    }

    @Test func duplicateReusesIDMovesToTopAndRefreshesSource() throws {
        var history = History()
        let first = clip("相同内容")
        try history.insert(first)
        try history.insert(clip("另一条内容"))
        let later = clip("相同内容", source: "Safari", date: Date().addingTimeInterval(30))
        try history.insert(later)
        #expect(history.clips.count == 2)
        #expect(history.clips.first?.id == first.id)
        #expect(history.clips.first?.sourceName == "Safari")
        #expect(history.clips.first?.copiedAt == later.copiedAt)
    }

    @Test func searchCombinesTermsAcrossContentAndSource() {
        let item = clip("项目 Meeting — Café", source: "Safari")
        #expect(item.matches("项目 safari"))
        #expect(item.matches("meeting cafe"))
        #expect(!item.matches("项目 缺席"))
        #expect(item.matches("  \n "))
    }

    @Test func differentKindsDoNotCollideAndWhitespaceIsPreserved() throws {
        var history = History()
        try history.insert(clip("hello"))
        try history.insert(clip("hello "))
        try history.insert(clip("hello", kind: .link))
        #expect(history.clips.count == 3)
    }

    @Test func capacityAndOversizeDoNotDiscardExistingHistory() throws {
        var history = History()
        for index in 0...History.maximumItems { try history.insert(clip("item \(index)")) }
        #expect(history.clips.count == History.maximumItems)
        #expect(history.clips.last?.text == "item 1")
        let original = history.clips
        let huge = Data(repeating: 1, count: History.maximumItemBytes + 1)
        let item = Clip(kind: .image, text: "large", sourceName: "test", sourceBundle: "",
                        items: [[Representation(type: "public.png", data: huge)]], identity: huge)
        #expect(throws: HistoryError.self) { try history.insert(item) }
        #expect(history.clips == original)
    }

    @Test func roundTripPreservesFormatsAndCorruptionIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        #expect(try History.load(from: url).clips.isEmpty)
        var history = History()
        let item = Clip(kind: .text, text: "hello", sourceName: "test", sourceBundle: "test.app",
                        items: [[Representation(type: "public.utf8-plain-text", data: Data("hello".utf8)),
                                 Representation(type: "public.rtf", data: Data("{\\rtf1 hello}".utf8))]], identity: Data("hello".utf8))
        try history.insert(item)
        try history.save(to: url)
        #expect(try History.load(from: url).clips == history.clips)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let bad = Data("corrupted data".utf8)
        try bad.write(to: url)
        #expect(throws: HistoryError.self) { try History.load(from: url) }
        #expect(try Data(contentsOf: url) == bad)
    }

    @Test func totalByteBudgetEvictsOldest() throws {
        var history = History()
        let payload = Data(repeating: 3, count: History.maximumItemBytes)
        for index in 0..<11 {
            let item = Clip(kind: .image, text: "\(index)", sourceName: "test", sourceBundle: "",
                            items: [[Representation(type: "public.png", data: payload)]], identity: Data("\(index)".utf8))
            try history.insert(item)
        }
        #expect(history.clips.count == 10)
        #expect(history.clips.last?.text == "1")
    }
}
