import Foundation
import CoreSpotlight
import CryptoKit
import UniformTypeIdentifiers
import ClipboardCore

struct SearchDocument: Equatable, Codable, Sendable {
    let id: UUID
    let text: String
    let title: String
    let source: String
    init(_ clip: Clip) { id = clip.id; text = clip.text; title = clip.title ?? ""; source = clip.sourceName }
    func matches(_ terms: [String]) -> Bool {
        terms.allSatisfy { text.localizedStandardContains($0) || title.localizedStandardContains($0) || source.localizedStandardContains($0) }
    }
}

protocol ClipboardSearchIndex: Actor {
    func synchronize(_ documents: [SearchDocument]) async throws
    func search(_ query: String) async throws -> Set<UUID>
}

actor MemorySearchIndex: ClipboardSearchIndex {
    private struct IndexedDocument {
        let document: SearchDocument
        let pinyin: [String]
        init(_ document: SearchDocument) {
            self.document = document
            // shortcut: use the system reading; add heteronyms if alternate pronunciations are needed.
            pinyin = [document.text, document.title, document.source].flatMap { value -> [String] in
                guard value.range(of: "\\p{Han}", options: .regularExpression) != nil,
                      let latin = value.applyingTransform(.mandarinToLatin, reverse: false) else { return [] }
                let syllables = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
                    .split(whereSeparator: \.isWhitespace)
                return [syllables.joined(), String(syllables.compactMap(\.first))]
            }
        }
        func matches(_ terms: [String]) -> Bool {
            terms.allSatisfy { term in
                document.matches([term]) || pinyin.contains { $0.localizedStandardContains(term) }
            }
        }
    }
    private var documents: [UUID: IndexedDocument] = [:]
    func synchronize(_ snapshot: [SearchDocument]) throws {
        var next: [UUID: IndexedDocument] = [:]
        for document in snapshot {
            try Task.checkCancellation()
            if let cached = documents[document.id], cached.document == document { next[document.id] = cached }
            else { next[document.id] = IndexedDocument(document) }
        }
        documents = next
    }
    func search(_ query: String) throws -> Set<UUID> {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var ids = Set<UUID>()
        for entry in documents.values {
            try Task.checkCancellation()
            if entry.matches(terms) { ids.insert(entry.document.id) }
        }
        return ids
    }
}

actor SpotlightSearchIndex: ClipboardSearchIndex {
    let domain: String
    private let index: CSSearchableIndex
    private var documents: [UUID: SearchDocument] = [:]
    private var prepared = false
    private let manifestURL: URL?
    private struct Entry: Codable { let signature: Data; let items: [String] }
    private struct Manifest: Codable { let token: Data; let entries: [UUID: Entry] }
    private var entries: [UUID: Entry] = [:]
    private var writes: Task<Void, Error>?
    private var latest: [SearchDocument] = []
    private var recovery: IndexRecovery?

    init(domain: String = "local.clipshelf.clipboard.v1", manifestURL: URL? = nil) {
        self.domain = domain
        self.manifestURL = manifestURL
        index = CSSearchableIndex(name: domain)
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
    }
    static func chunks(_ text: String) -> [String] {
        guard !text.isEmpty else { return [""] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 5000, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            if end == text.endIndex { break }
            start = text.index(end, offsetBy: -64)
        }
        return chunks
    }
    func synchronize(_ snapshot: [SearchDocument]) async throws {
        latest = snapshot
        let previous = writes
        let task = Task {
            _ = try? await previous?.value
            try await self.apply(snapshot)
        }
        writes = task
        try await task.value
    }
    private func rebuild() async -> Bool {
        _ = try? await writes?.value
        prepared = false
        if let manifestURL { try? FileManager.default.removeItem(at: manifestURL) }
        do { try await synchronize(latest); return true }
        catch { return false }
    }
    private func apply(_ snapshot: [SearchDocument]) async throws {
        if recovery == nil {
            let delegate = IndexRecovery { [weak self] acknowledge in
                Task(priority: .utility) { if await self?.rebuild() == true { acknowledge() } }
            }
            recovery = delegate; index.indexDelegate = delegate
        }
        if !prepared {
            let manifest = manifestURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? PropertyListDecoder().decode(Manifest.self, from: $0) }
            let state = try await index.fetchLastClientState()
            if let manifest, manifest.token == state {
                entries = manifest.entries
            } else {
                try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
                entries = [:]
            }
            prepared = true
        }
        let next = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var signatures: [UUID: Data] = [:]
        var changed: [SearchDocument] = []
        for document in snapshot {
            let digest: Data
            if documents[document.id] == document, let entry = entries[document.id] { digest = entry.signature }
            else { digest = Data(SHA256.hash(data: try encoder.encode(document))) }
            signatures[document.id] = digest
            if entries[document.id]?.signature != digest { changed.append(document) }
        }
        let removed = Set(entries.keys).subtracting(next.keys).union(changed.map(\.id))
        guard !removed.isEmpty || !changed.isEmpty else { documents = next; return }
        let stale = removed.flatMap { entries[$0]?.items ?? [] }
        var updated = entries.filter { !removed.contains($0.key) }
        var batchOpen = true
        index.beginBatch()
        do {
            if !stale.isEmpty { try await index.deleteSearchableItems(withIdentifiers: stale) }
            var batch: [CSSearchableItem] = []
            for document in changed {
                var ids: [String] = []
                for (part, text) in Self.chunks(document.text).enumerated() {
                    let attributes = CSSearchableItemAttributeSet(contentType: .text)
                    attributes.title = document.title
                    attributes.textContent = text
                    attributes.keywords = [document.source]
                    let id = "\(document.id.uuidString):\(part)"
                    let item = CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: attributes)
                    item.expirationDate = .distantFuture
                    ids.append(id); batch.append(item)
                    if batch.count == 100 { try await index.indexSearchableItems(batch); batch.removeAll(keepingCapacity: true) }
                }
                updated[document.id] = Entry(signature: signatures[document.id]!, items: ids)
            }
            if !batch.isEmpty { try await index.indexSearchableItems(batch) }
            let token = Data(UUID().uuidString.utf8)
            batchOpen = false
            try await index.endBatch(withClientState: token)
            if let manifestURL {
                try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try PropertyListEncoder().encode(Manifest(token: token, entries: updated)).write(to: manifestURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            }
            documents = next; entries = updated
        } catch {
            if batchOpen { try? await index.endBatch(withClientState: Data()) }
            prepared = false
            if let manifestURL { try? FileManager.default.removeItem(at: manifestURL) }
            throw error
        }
    }
    func search(_ query: String) async throws -> Set<UUID> {
        try await writes?.value
        try Task.checkCancellation()
        let terms = Array(Set(query.split(whereSeparator: \.isWhitespace).map(String.init)))
        if terms.isEmpty { return Set(documents.keys) }
        // Longer literals can span the overlap; keep exact coverage in the background fallback.
        if terms.count > 32 || terms.contains(where: { $0.count > 64 }) {
            var found = Set<UUID>()
            for document in documents.values {
                try Task.checkCancellation()
                if document.matches(terms) { found.insert(document.id) }
            }
            return found
        }
        let domain = self.domain
        return try await withThrowingTaskGroup(of: Set<UUID>.self) { group in
            for term in terms { group.addTask { try await Self.matchingIDs(term, domain: domain) } }
            var matches: Set<UUID>?
            for try await ids in group {
                matches = matches.map { $0.intersection(ids) } ?? ids
                if matches?.isEmpty == true { group.cancelAll(); break }
            }
            return matches ?? []
        }
    }
    private static func matchingIDs(_ term: String, domain: String) async throws -> Set<UUID> {
        try Task.checkCancellation()
        let value = escape(term)
        let context = CSSearchQueryContext()
        context.fetchAttributes = []
        context.filterQueries = ["domainIdentifier == \"\(escape(domain))\""]
        let predicate = ["title", "textContent", "keywords"].map { "\($0) == \"*\(value)*\"cd" }.joined(separator: " || ")
        let search = CSSearchQuery(queryString: "(\(predicate))", queryContext: context)
        return try await withTaskCancellationHandler(operation: {
            var found = Set<UUID>()
            for try await result in search.results {
                try Task.checkCancellation()
                if let id = UUID(uuidString: String(result.item.uniqueIdentifier.prefix(36))) { found.insert(id) }
            }
            return found
        }, onCancel: { search.cancel() })
    }
    func removeAll() async throws {
        _ = try? await writes?.value
        latest = []
        try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        prepared = false; documents = [:]; entries = [:]
        if let manifestURL { try? FileManager.default.removeItem(at: manifestURL) }
    }
}


private final class IndexRecovery: NSObject, CSSearchableIndexDelegate {
    let rebuild: (@escaping () -> Void) -> Void
    init(_ rebuild: @escaping (@escaping () -> Void) -> Void) { self.rebuild = rebuild }
    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) { rebuild(acknowledgementHandler) }
    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) { rebuild(acknowledgementHandler) }
}
