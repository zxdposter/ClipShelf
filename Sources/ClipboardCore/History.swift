import Foundation
import CryptoKit
import UniformTypeIdentifiers

public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, link, image, files
}

public struct Representation: Codable, Equatable, Sendable {
    public let type: String
    public let data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
}

public func singleImageRepresentation(in items: [[Representation]]) -> Representation? {
    guard items.count == 1, let item = items.first else { return nil }
    let files = item.filter { $0.type == "public.file-url" }
    if !files.isEmpty {
        // A PDF or folder can also provide a thumbnail; only image files take precedence.
        guard files.count == 1, let value = String(data: files[0].data, encoding: .utf8),
              let url = URL(string: value), url.isFileURL, !url.hasDirectoryPath,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
    }
    return item.first { $0.type == "public.png" || $0.type == "public.tiff" }
}

public struct Clip: Codable, Identifiable, Equatable, Sendable {
    public internal(set) var id: UUID
    public let fingerprint: String
    public let kind: ClipKind
    public let text: String
    public let sourceName: String
    public let sourceBundle: String
    public var title: String?
    public var copiedAt: Date
    public let items: [[Representation]]
    public var byteCount: Int { items.flatMap { $0 }.reduce(0) { $0 + $1.data.count } }

    struct Metadata: Codable, Equatable {
        let id: UUID
        let fingerprint: String
        let kind: ClipKind
        let sourceName: String
        let sourceBundle: String
        let title: String?
        let copiedAt: Date
        init(_ clip: Clip) {
            id = clip.id; fingerprint = clip.fingerprint; kind = clip.kind
            sourceName = clip.sourceName; sourceBundle = clip.sourceBundle
            title = clip.title; copiedAt = clip.copiedAt
        }
    }
    struct Payload: Codable {
        let text: String
        let items: [[Representation]]
        init(_ clip: Clip) { text = clip.text; items = clip.items }
    }
    init(metadata: Metadata, payload: Payload) {
        id = metadata.id; fingerprint = metadata.fingerprint; kind = metadata.kind; text = payload.text
        sourceName = metadata.sourceName; sourceBundle = metadata.sourceBundle
        title = metadata.title; copiedAt = metadata.copiedAt; items = payload.items
    }

    public init(kind: ClipKind, text: String, sourceName: String, sourceBundle: String,
                items: [[Representation]], identity: Data, copiedAt: Date = Date()) {
        id = UUID()
        // Type separates equal bytes representing different kinds of content.
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: identity)
        fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        self.kind = kind; self.text = text; self.sourceName = sourceName
        self.sourceBundle = sourceBundle; self.items = items; self.copiedAt = copiedAt
    }

    public func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        let content = text + " " + sourceName + " " + (title ?? "")
        return terms.allSatisfy { content.localizedStandardContains(String($0)) }
    }
}

public struct Pinboard: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var color: Int
    public var clipIDs: [UUID]
    public init(name: String, color: Int = 0) {
        id = UUID(); self.name = name; self.color = color; clipIDs = []
    }
}

public enum HistoryError: LocalizedError {
    case invalidArchive, invalidBoard
    public var errorDescription: String? {
        switch self {
        case .invalidBoard: return "分组名称需为 1–80 个字符，最多保存 100 个分组。"
        case .invalidArchive: return "历史文件无法读取。原文件已保留；请先处理该文件再重新启动。"
        }
    }
}

public struct History: Sendable {
    public private(set) var clips: [Clip]
    public private(set) var boards: [Pinboard]
    private struct Archive: Codable {
        let version: Int
        let clips: [Clip]
        let boards: [Pinboard]
    }
    public init(clips: [Clip] = [], boards: [Pinboard] = [Pinboard(name: "实用链接")]) {
        self.clips = clips; self.boards = boards
    }

    @discardableResult public mutating func addBoard(name: String, color: Int) throws -> UUID {
        guard boards.count < 100 else { throw HistoryError.invalidBoard }
        let board = Pinboard(name: name, color: color)
        try validateBoard(board)
        boards.append(board)
        return board.id
    }
    public mutating func editBoard(id: UUID, name: String, color: Int) throws {
        guard let index = boards.firstIndex(where: { $0.id == id }) else { return }
        var next = boards[index]; next.name = name; next.color = color
        try validateBoard(next)
        boards[index] = next
    }
    private func validateBoard(_ board: Pinboard) throws {
        guard !board.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              board.name.count <= 80, (0..<6).contains(board.color) else { throw HistoryError.invalidBoard }
    }
    public mutating func removeBoard(id: UUID) { boards.removeAll { $0.id == id } }
    public mutating func addToBoard(clipID: UUID, boardID: UUID) {
        guard clips.contains(where: { $0.id == clipID }),
              let index = boards.firstIndex(where: { $0.id == boardID }),
              !boards[index].clipIDs.contains(clipID) else { return }
        boards[index].clipIDs.insert(clipID, at: 0)
    }
    public mutating func removeFromBoard(clipID: UUID, boardID: UUID) {
        guard let index = boards.firstIndex(where: { $0.id == boardID }) else { return }
        boards[index].clipIDs.removeAll { $0 == clipID }
    }
    public mutating func moveBoard(id: UUID, before target: UUID) {
        guard id != target, let old = boards.firstIndex(where: { $0.id == id }) else { return }
        let board = boards.remove(at: old)
        let index = boards.firstIndex(where: { $0.id == target }) ?? boards.endIndex
        boards.insert(board, at: index)
    }

    public mutating func insert(_ clip: Clip) throws {
        if let index = clips.firstIndex(where: { $0.fingerprint == clip.fingerprint }) {
            // Reuse the existing identity while refreshing content and its source.
            let old = clips.remove(at: index)
            var refreshed = clip
            refreshed.id = old.id
            refreshed.title = old.title
            clips.insert(refreshed, at: 0)
        } else { clips.insert(clip, at: 0) }
    }

    public struct Deletion {
        fileprivate let entries: [(index: Int, clip: Clip)]
        fileprivate let boards: [Pinboard]
        public var byteCount: Int { entries.reduce(0) { $0 + $1.clip.byteCount } }
    }
    public func deletion(for ids: Set<UUID>) -> Deletion {
        Deletion(entries: clips.enumerated().filter { ids.contains($0.element.id) }.map { ($0.offset, $0.element) },
                 boards: boards.filter { !$0.clipIDs.allSatisfy { !ids.contains($0) } })
    }
    public mutating func restore(_ deletion: Deletion) throws {
        var next = self
        var restored: [UUID: UUID] = [:]
        for entry in deletion.entries {
            if let existing = next.clips.first(where: { $0.id == entry.clip.id || $0.fingerprint == entry.clip.fingerprint }) {
                restored[entry.clip.id] = existing.id
            } else {
                next.clips.insert(entry.clip, at: min(entry.index, next.clips.count))
                restored[entry.clip.id] = entry.clip.id
            }
        }
        for previous in deletion.boards {
            guard let boardIndex = next.boards.firstIndex(where: { $0.id == previous.id }) else { continue }
            for (index, id) in previous.clipIDs.enumerated() {
                if let id = restored[id], !next.boards[boardIndex].clipIDs.contains(id) {
                    next.boards[boardIndex].clipIDs.insert(id, at: min(index, next.boards[boardIndex].clipIDs.count))
                }
            }
        }
        self = next
    }

    public mutating func rename(id: UUID, title: String) throws {
        guard title.count <= 200 else { throw HistoryError.invalidArchive }
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        clips[index].title = name.isEmpty ? nil : name
    }
    public mutating func editText(id: UUID, text: String) throws {
        guard let index = clips.firstIndex(where: { $0.id == id }), [.text, .link].contains(clips[index].kind) else { return }
        let old = clips[index]
        let edited = Clip(kind: old.kind, text: text, sourceName: old.sourceName, sourceBundle: old.sourceBundle,
                          items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]],
                          identity: Data(text.utf8), copiedAt: old.copiedAt)
        try replace(id: id, with: edited)
    }
    public mutating func editImage(id: UUID, png: Data) throws {
        guard let old = clips.first(where: { $0.id == id }), old.kind == .image else { return }
        let edited = Clip(kind: .image, text: old.text, sourceName: old.sourceName, sourceBundle: old.sourceBundle,
                          items: [[Representation(type: "public.png", data: png)]], identity: png, copiedAt: old.copiedAt)
        try replace(id: id, with: edited)
    }
    @discardableResult public mutating func reclassifyImageFiles() throws -> Bool {
        let images = clips.filter { $0.kind == .files && singleImageRepresentation(in: $0.items) != nil }
        for old in images {
            guard let image = singleImageRepresentation(in: old.items) else { continue }
            let corrected = Clip(kind: .image, text: old.text, sourceName: old.sourceName, sourceBundle: old.sourceBundle,
                                 items: old.items, identity: image.data, copiedAt: old.copiedAt)
            try replace(id: old.id, with: corrected)
        }
        return !images.isEmpty
    }
    private mutating func replace(id: UUID, with replacement: Clip) throws {
        guard let old = clips.first(where: { $0.id == id }) else { return }
        var edited = replacement
        edited.id = id; edited.title = old.title
        // Merge duplicate content into the edited card, preserving every board membership.
        if let duplicate = clips.first(where: { $0.id != id && $0.fingerprint == edited.fingerprint }) {
            for i in boards.indices where boards[i].clipIDs.contains(duplicate.id) {
                boards[i].clipIDs = boards[i].clipIDs.map { $0 == duplicate.id ? id : $0 }
                var seen = Set<UUID>()
                boards[i].clipIDs = boards[i].clipIDs.filter { seen.insert($0).inserted }
            }
            clips.removeAll { $0.id == duplicate.id }
        }
        if let current = clips.firstIndex(where: { $0.id == id }) { clips[current] = edited }
    }
    public mutating func prune(before cutoff: Date) {
        let pinned = Set(boards.flatMap(\.clipIDs))
        clips.removeAll { $0.copiedAt < cutoff && !pinned.contains($0.id) }
    }
    public mutating func removeUnpinned() {
        let pinned = Set(boards.flatMap(\.clipIDs))
        clips.removeAll { !pinned.contains($0.id) }
    }

    public mutating func remove(id: UUID) {
        clips.removeAll { $0.id == id }
        for index in boards.indices { boards[index].clipIDs.removeAll { $0 == id } }
    }

    public static func load(from url: URL) throws -> History {
        guard FileManager.default.fileExists(atPath: url.path) else { return History() }
        if try HistoryDatabase.isDatabase(at: url) { return try HistoryDatabase.read(from: url) }
        let clips: [Clip]
        let boards: [Pinboard]
        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            if let archive = try? decoder.decode(Archive.self, from: data) {
                guard archive.version == 1 else { throw HistoryError.invalidArchive }
                clips = archive.clips; boards = archive.boards
            } else {
                // Migrate the original array archive without losing clipboard representations.
                clips = try decoder.decode([Clip].self, from: data)
                boards = [Pinboard(name: "实用链接")]
            }
        }
        catch {
            // A concurrent reader can cross the atomic legacy-to-database replacement.
            if (try? HistoryDatabase.isDatabase(at: url)) == true { return try HistoryDatabase.read(from: url) }
            throw HistoryError.invalidArchive
        }
        return try validated(clips: clips, boards: boards)
    }

    static func validated(clips: [Clip], boards: [Pinboard]) throws -> History {
        guard clips.allSatisfy({ ($0.title?.count ?? 0) <= 200 }),
              Set(clips.map(\.id)).count == clips.count,
              Set(clips.map(\.fingerprint)).count == clips.count
        else { throw HistoryError.invalidArchive }
        let ids = Set(clips.map(\.id))
        guard boards.count <= 100, Set(boards.map(\.id)).count == boards.count,
              boards.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 &&
                  (0..<6).contains($0.color) &&
                  Set($0.clipIDs).count == $0.clipIDs.count && Set($0.clipIDs).isSubset(of: ids) })
        else { throw HistoryError.invalidArchive }
        return History(clips: clips, boards: boards)
    }

    public func save(to url: URL) throws {
        try HistoryDatabase(url: url).save(self)
    }
}
