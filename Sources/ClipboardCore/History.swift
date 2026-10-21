import Foundation
import CryptoKit

public enum ClipKind: String, Codable, CaseIterable {
    case text, link, image, files
}

public struct Representation: Codable, Equatable {
    public let type: String
    public let data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
}

public struct Clip: Codable, Identifiable, Equatable {
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

    public init(kind: ClipKind, text: String, sourceName: String, sourceBundle: String,
                items: [[Representation]], identity: Data, copiedAt: Date = Date()) {
        id = UUID()
        // Type separates equal bytes representing different kinds of content.
        fingerprint = SHA256.hash(data: Data(kind.rawValue.utf8) + Data([0]) + identity)
            .map { String(format: "%02x", $0) }.joined()
        self.kind = kind; self.text = text; self.sourceName = sourceName
        self.sourceBundle = sourceBundle; self.items = items; self.copiedAt = copiedAt
    }

    public func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        let content = text + " " + sourceName + " " + (title ?? "")
        return terms.allSatisfy { content.localizedStandardContains(String($0)) }
    }
}

public struct Pinboard: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var color: Int
    public var clipIDs: [UUID]
    public init(name: String, color: Int = 0) {
        id = UUID(); self.name = name; self.color = color; clipIDs = []
    }
}

public enum HistoryError: LocalizedError {
    case oversized, invalidArchive, invalidBoard, capacity
    public var errorDescription: String? {
        switch self {
        case .capacity: return "分组已占满历史容量，请先移除部分卡片再继续采集。"
        case .invalidBoard: return "分组名称需为 1–80 个字符，最多保存 100 个分组。"
        case .oversized: return "内容超过 5 MB，未保存。"
        case .invalidArchive: return "历史文件无法读取。原文件已保留；请先处理该文件再重新启动。"
        }
    }
}

public struct History {
    public static let maximumItems = 200
    public static let maximumItemBytes = 5 * 1024 * 1024
    public static let maximumHistoryBytes = 50 * 1024 * 1024
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
        guard clip.byteCount <= Self.maximumItemBytes else { throw HistoryError.oversized }
        if let index = clips.firstIndex(where: { $0.fingerprint == clip.fingerprint }) {
            // Reuse the existing identity while refreshing content and its source.
            let old = clips.remove(at: index)
            var refreshed = clip
            refreshed.id = old.id
            refreshed.title = old.title
            clips.insert(refreshed, at: 0)
        } else { clips.insert(clip, at: 0) }
        try trim(to: Self.maximumItems)
        if !clips.contains(where: { $0.fingerprint == clip.fingerprint }) { throw HistoryError.capacity }
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
        guard next.clips.count <= Self.maximumItems,
              next.clips.reduce(0, { $0 + $1.byteCount }) <= Self.maximumHistoryBytes else { throw HistoryError.capacity }
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
        guard text.utf8.count <= Self.maximumItemBytes else { throw HistoryError.oversized }
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
    private mutating func replace(id: UUID, with replacement: Clip) throws {
        guard let old = clips.first(where: { $0.id == id }) else { return }
        guard replacement.byteCount <= Self.maximumItemBytes else { throw HistoryError.oversized }
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
        try trim(to: Self.maximumItems)
    }

    public mutating func trim(to limit: Int) throws {
        guard (1...Self.maximumItems).contains(limit) else { throw HistoryError.invalidArchive }
        let pinned = Set(boards.flatMap(\.clipIDs))
        guard pinned.count <= limit else { throw HistoryError.capacity }
        var size = clips.reduce(0) { $0 + $1.byteCount }
        while clips.count > limit || size > Self.maximumHistoryBytes {
            guard let index = clips.lastIndex(where: { !pinned.contains($0.id) }) else { throw HistoryError.capacity }
            size -= clips.remove(at: index).byteCount
        }
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
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumHistoryBytes * 2 + 1_048_576 else { throw HistoryError.invalidArchive }
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
        catch { throw HistoryError.invalidArchive }
        guard clips.count <= maximumItems,
              clips.allSatisfy({ $0.byteCount <= maximumItemBytes && ($0.title?.count ?? 0) <= 200 }),
              clips.reduce(0, { $0 + $1.byteCount }) <= maximumHistoryBytes,
              Set(clips.map(\.id)).count == clips.count,
              Set(clips.map(\.fingerprint)).count == clips.count
        else { throw HistoryError.invalidArchive }
        let ids = Set(clips.map(\.id))
        guard boards.count <= 100, Set(boards.map(\.id)).count == boards.count,
              boards.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 &&
                  (0..<6).contains($0.color) && $0.clipIDs.count <= maximumItems &&
                  Set($0.clipIDs).count == $0.clipIDs.count && Set($0.clipIDs).isSubset(of: ids) })
        else { throw HistoryError.invalidArchive }
        return History(clips: clips, boards: boards)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(Archive(version: 1, clips: clips, boards: boards)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
