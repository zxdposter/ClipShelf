import Foundation
import SQLite3
import Darwin

// One record per card: new copies never serialize or rewrite older card payloads.
final class HistoryDatabase {
    private struct Manifest: Codable {
        let order: [UUID]
        let boards: [Pinboard]
    }
    private let url: URL
    private var db: OpaquePointer?
    private var previous: History?
    private let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary; return encoder
    }()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) { self.url = url }
    deinit { if let db { sqlite3_close_v2(db) } }

    static func isDatabase(at url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: 16) == Data("SQLite format 3\0".utf8)
    }
    static func read(from url: URL) throws -> History {
        let store = HistoryDatabase(url: url)
        try store.open(url, flags: SQLITE_OPEN_READONLY)
        return try store.read()
    }
    private func open(_ url: URL, flags: Int32) throws {
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db, 2000)
        try execute("PRAGMA foreign_keys=ON")
    }
    private func failure() -> NSError {
        NSError(domain: "ClipShelf.HistoryStorage", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开历史数据库。"])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure() }
        return value
    }
    private func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = data.withUnsafeBytes { sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64($0.count), transient) }
        guard result == SQLITE_OK else { throw failure() }
    }
    private func bind(_ id: UUID, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, id.uuidString, -1, transient) == SQLITE_OK else { throw failure() }
    }
    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func data(_ statement: OpaquePointer, at index: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { throw HistoryError.invalidArchive }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
    private func read() throws -> History {
        try execute("BEGIN")
        defer { try? execute("ROLLBACK") }
        let version = try statement("PRAGMA user_version")
        defer { sqlite3_finalize(version) }
        guard sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int(version, 0) == 1 else { throw HistoryError.invalidArchive }
        let state = try statement("SELECT record FROM state WHERE id = 1")
        defer { sqlite3_finalize(state) }
        guard sqlite3_step(state) == SQLITE_ROW else { throw HistoryError.invalidArchive }
        let decoder = PropertyListDecoder()
        let manifest = try decoder.decode(Manifest.self, from: data(state, at: 0))
        let rows = try statement("SELECT clips.id, clips.metadata, payloads.record FROM clips JOIN payloads USING(id)")
        defer { sqlite3_finalize(rows) }
        var clips: [UUID: Clip] = [:]
        while true {
            let result = sqlite3_step(rows)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let id = sqlite3_column_text(rows, 0) else { throw failure() }
            let metadata = try decoder.decode(Clip.Metadata.self, from: data(rows, at: 1))
            let payload = try decoder.decode(Clip.Payload.self, from: data(rows, at: 2))
            let clip = Clip(metadata: metadata, payload: payload)
            guard clip.id.uuidString == String(cString: id), clips[clip.id] == nil else { throw HistoryError.invalidArchive }
            clips[clip.id] = clip
        }
        guard Set(manifest.order).count == manifest.order.count, Set(manifest.order) == Set(clips.keys) else { throw HistoryError.invalidArchive }
        return try History.validated(clips: manifest.order.compactMap { clips[$0] }, boards: manifest.boards)
    }

    func save(_ history: History) throws {
        _ = try History.validated(clips: history.clips, boards: history.boards)
        if db == nil {
            do {
                if FileManager.default.fileExists(atPath: url.path), try Self.isDatabase(at: url) {
                    try open(url, flags: SQLITE_OPEN_READWRITE)
                    previous = try read()
                } else {
                    // Validate first; a corrupt legacy file must never be replaced by an empty store.
                    _ = try History.load(from: url)
                    try migrate(history)
                    previous = history
                    try open(url, flags: SQLITE_OPEN_READWRITE)
                }
                try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON")
            } catch {
                if let db { sqlite3_close_v2(db) }; db = nil; previous = nil
                throw error
            }
        }
        try write(history)
    }
    private func migrate(_ history: History) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".history-\(UUID().uuidString).sqlite")
        defer { try? manager.removeItem(at: temporary) }
        // Create the file privately before SQLite opens it.
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw HistoryError.invalidArchive }
        do {
            try open(temporary, flags: SQLITE_OPEN_READWRITE)
            try execute("CREATE TABLE clips (id TEXT PRIMARY KEY NOT NULL, metadata BLOB NOT NULL); CREATE TABLE payloads (id TEXT PRIMARY KEY NOT NULL REFERENCES clips(id) ON DELETE CASCADE, record BLOB NOT NULL); CREATE TABLE state (id INTEGER PRIMARY KEY CHECK(id = 1), record BLOB NOT NULL); PRAGMA user_version=1")
            try write(history)
            guard sqlite3_close(db) == SQLITE_OK else { throw failure() }
            db = nil
            if manager.fileExists(atPath: url.path) {
                let backup = url.appendingPathExtension("legacy-backup")
                if !manager.fileExists(atPath: backup.path) {
                    try manager.copyItem(at: url, to: backup)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
            }
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            if let db { sqlite3_close_v2(db) }; db = nil; previous = nil
            throw error
        }
    }
    private func write(_ history: History) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let old = Dictionary(uniqueKeysWithValues: (previous?.clips ?? []).map { ($0.id, $0) })
            let ids = Set(history.clips.map(\.id))
            let remove = try statement("DELETE FROM clips WHERE id = ?")
            defer { sqlite3_finalize(remove) }
            for id in old.keys where !ids.contains(id) {
                sqlite3_reset(remove); sqlite3_clear_bindings(remove)
                try bind(id, to: remove, at: 1); try done(remove)
            }
            let insert = try statement("INSERT INTO clips(id, metadata) VALUES(?, ?)")
            defer { sqlite3_finalize(insert) }
            let insertPayload = try statement("INSERT INTO payloads(id, record) VALUES(?, ?)")
            defer { sqlite3_finalize(insertPayload) }
            let metadata = try statement("UPDATE clips SET metadata = ? WHERE id = ?")
            defer { sqlite3_finalize(metadata) }
            let payload = try statement("UPDATE payloads SET record = ? WHERE id = ?")
            defer { sqlite3_finalize(payload) }
            for clip in history.clips {
                if let prior = old[clip.id] {
                    if Clip.Metadata(prior) != Clip.Metadata(clip) {
                        sqlite3_reset(metadata); sqlite3_clear_bindings(metadata)
                        try bind(encoder.encode(Clip.Metadata(clip)), to: metadata, at: 1)
                        try bind(clip.id, to: metadata, at: 2); try done(metadata)
                    }
                    if prior.text != clip.text || prior.items != clip.items {
                        sqlite3_reset(payload); sqlite3_clear_bindings(payload)
                        try bind(encoder.encode(Clip.Payload(clip)), to: payload, at: 1)
                        try bind(clip.id, to: payload, at: 2); try done(payload)
                    }
                } else {
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    try bind(clip.id, to: insert, at: 1)
                    try bind(encoder.encode(Clip.Metadata(clip)), to: insert, at: 2); try done(insert)
                    sqlite3_reset(insertPayload); sqlite3_clear_bindings(insertPayload)
                    try bind(clip.id, to: insertPayload, at: 1)
                    try bind(encoder.encode(Clip.Payload(clip)), to: insertPayload, at: 2); try done(insertPayload)
                }
            }
            let order = history.clips.map(\.id)
            if previous?.clips.map(\.id) != order || previous?.boards != history.boards {
                let state = try statement("INSERT INTO state(id, record) VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET record=excluded.record")
                defer { sqlite3_finalize(state) }
                try bind(encoder.encode(Manifest(order: order, boards: history.boards)), to: state, at: 1); try done(state)
            }
            try execute("COMMIT")
            previous = history
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

// Serial disk work stays off the main actor; snapshots retain Data without copying payloads.
public final class HistoryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.clipshelf.history-writer", qos: .utility)
    private let database: HistoryDatabase
    private var result: Result<Void, Error> = .success(())
    public init(url: URL) { database = HistoryDatabase(url: url) }
    public func save(_ history: History, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            self.result = Result { try self.database.save(history) }
            completion(self.result)
        }
    }
    public func flush() throws { try queue.sync { try result.get() } }
    public func finish(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { completion(self.result) }
    }
}
