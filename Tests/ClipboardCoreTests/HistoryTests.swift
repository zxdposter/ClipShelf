import Foundation
import Testing
import SQLite3
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

    @Test func itemCountAndIndividualSizeAreUnlimited() throws {
        var history = History()
        for index in 0..<350 { try history.insert(clip("item \(index)")) }
        #expect(history.clips.count == 350)
        #expect(history.clips.last?.text == "item 0")
        let original = history.clips
        let huge = Data(repeating: 1, count: 6 * 1024 * 1024)
        let item = Clip(kind: .image, text: "large", sourceName: "test", sourceBundle: "",
                        items: [[Representation(type: "public.png", data: huge)]], identity: huge)
        try history.insert(item)
        #expect(history.clips.first == item)
        #expect(Array(history.clips.dropFirst()) == original)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try history.save(to: url)
        #expect(try History.load(from: url).clips == history.clips)
        let text = String(repeating: "x", count: 6 * 1024 * 1024)
        try history.editText(id: original[0].id, text: text)
        #expect(history.clips.first { $0.id == original[0].id }?.text == text)
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
        struct LegacyArchive: Encodable { let version: Int; let clips: [Clip]; let boards: [Pinboard] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = try PropertyListEncoder().encode(LegacyArchive(version: 1, clips: history.clips, boards: history.boards))
        try legacy.write(to: url)
        try history.save(to: url)
        #expect(try Data(contentsOf: url.appendingPathExtension("legacy-backup")) == legacy)
        #expect(try History.load(from: url).clips == history.clips)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let bad = Data("corrupted data".utf8)
        try bad.write(to: url)
        #expect(throws: HistoryError.self) { try History.load(from: url) }
        #expect(throws: (any Error).self) { try history.save(to: url) }
        #expect(try Data(contentsOf: url) == bad)
    }

    @Test func incrementalWritesSkipOldPayloadsAndRollbackFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        var history = History()
        let original = clip("old")
        try history.insert(original)
        let database = HistoryDatabase(url: url)
        try database.save(history)
        var audit: OpaquePointer?
        #expect(sqlite3_open(url.path, &audit) == SQLITE_OK)
        defer { sqlite3_close(audit) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(audit, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryError.invalidArchive }
        }
        try execute("CREATE TABLE payload_writes (id TEXT); CREATE TRIGGER record_payload_write AFTER UPDATE OF record ON payloads BEGIN INSERT INTO payload_writes VALUES(NEW.id); END")
        try history.rename(id: original.id, title: "renamed")
        try database.save(history)
        try history.insert(clip("old"))
        try database.save(history)
        try history.insert(clip("new"))
        try database.save(history)
        var query: OpaquePointer?
        #expect(sqlite3_prepare_v2(audit, "SELECT count(*) FROM payload_writes", -1, &query, nil) == SQLITE_OK)
        #expect(sqlite3_step(query) == SQLITE_ROW)
        #expect(sqlite3_column_int(query, 0) == 0)
        sqlite3_finalize(query)
        let saved = history
        try execute("BEGIN IMMEDIATE; DELETE FROM clips")
        #expect(try History.load(from: url).clips == saved.clips)
        try execute("ROLLBACK")
        for suffix in ["", "-wal", "-shm"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path + suffix)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        try execute("CREATE TRIGGER reject_insert BEFORE INSERT ON clips BEGIN SELECT RAISE(ABORT, 'test write failure'); END")
        history.remove(id: original.id)
        try history.insert(clip("retry"))
        #expect(throws: (any Error).self) { try database.save(history) }
        #expect(try History.load(from: url).clips == saved.clips)
        try execute("DROP TRIGGER reject_insert")
        try database.save(history)
        #expect(try History.load(from: url).clips == history.clips)
    }

    @Test func backgroundWriterPreservesOrderAndReportsDiskErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let writer = HistoryWriter(url: url)
        var history = History()
        try history.insert(clip("first"))
        let firstOffMain: Bool = await withCheckedContinuation { continuation in
            writer.save(history) { result in
                continuation.resume(returning: !Thread.isMainThread && (try? result.get()) != nil)
            }
        }
        #expect(firstOffMain)
        try history.insert(clip("second"))
        writer.save(history) { _ in }
        try history.insert(clip("third"))
        writer.save(history) { _ in }
        try writer.flush()
        #expect(try History.load(from: url).clips == history.clips)
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blocked)
        let failed = HistoryWriter(url: blocked.appendingPathComponent("history.plist"))
        failed.save(history) { _ in }
        #expect(throws: (any Error).self) { try failed.flush() }
        #expect(try Data(contentsOf: blocked) == Data([0]))
    }

    @Test func historyOverFormerCountAndByteLimitsSurvivesReloadAndUndo() throws {
        var history = History()
        for index in 0..<250 { try history.insert(clip("text \(index)")) }
        let payload = Data(repeating: 3, count: 5 * 1024 * 1024)
        for index in 0..<21 {
            let item = Clip(kind: .image, text: "\(index)", sourceName: "test", sourceBundle: "",
                            items: [[Representation(type: "public.png", data: payload)]], identity: Data("\(index)".utf8))
            try history.insert(item)
        }
        #expect(history.clips.count == 271)
        #expect(history.clips.last?.text == "text 0")
        let board = try #require(history.boards.first?.id)
        for item in history.clips { history.addToBoard(clipID: item.id, boardID: board) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try history.save(to: url)
        let loaded = try History.load(from: url)
        #expect(loaded.clips == history.clips && loaded.boards == history.boards)
        let item = try #require(history.clips.first)
        let deletion = history.deletion(for: [item.id])
        history.remove(id: item.id)
        try history.restore(deletion)
        #expect(history.clips == loaded.clips && history.boards == loaded.boards)
    }
}
