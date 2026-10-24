import Foundation
import Vision
import ImageIO
import SQLite3
import ClipboardCore

struct RecognizedImageText: Codable, Equatable, Sendable {
    let text: String
    let terms: [String]
    var regions: [ImageTextRegion] = []
    init(_ text: String, regions: [ImageTextRegion] = []) {
        self.text = text
        terms = [foldedSearchText(text)] + pinyinSearchTerms(text).map(foldedSearchText)
        self.regions = regions
    }
    func matchingRegions(_ query: String) -> [CGRect] {
        let tokens = foldedSearchText(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        return tokens.flatMap { token in
            let matches = regions.filter { $0.terms.contains { $0.contains(token) } }.map(\.bounds)
            return matches.filter { box in !matches.contains { $0 != box && box.contains($0) } }
        }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

struct ImageTextRegion: Codable, Equatable, Sendable {
    let bounds: CGRect
    let terms: [String]
    init(text: String, bounds: CGRect) {
        self.bounds = bounds
        terms = [foldedSearchText(text)] + pinyinSearchTerms(text).map(foldedSearchText)
    }
}

enum LocalImageOCR {
    static func recognize(_ data: Data, register: (VNRequest?) -> Void = { _ in }) throws -> String {
        try recognizeText(data, register: register).text
    }
    static func recognizeText(_ data: Data, register: (VNRequest?) -> Void = { _ in }) throws -> RecognizedImageText {
        // shortcut: bound decoded memory at a 4096px edge; tile very long screenshots if small-text recall needs improvement.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let request = VNRecognizeTextRequest()
        // shortcut: pin the Chinese-capable CPU engine; revalidate newer revisions before switching (model initialization can stall).
        request.revision = VNRecognizeTextRequestRevision2
        register(request)
        defer { register(nil) }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0
        request.preferBackgroundProcessing = true
        request.usesCPUOnly = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        var lines: [String] = []
        var regions: [ImageTextRegion] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(candidate.string)
            // Keep word coordinates so rendering never needs to run recognition again.
            candidate.string.enumerateSubstrings(in: candidate.string.startIndex..., options: .byWords) { word, range, _, _ in
                guard let word, let box = try? candidate.boundingBox(for: range) else { return }
                regions.append(ImageTextRegion(text: word, bounds: box.boundingBox))
            }
            // Whole-line terms also locate phrases and joined pinyin spanning multiple words.
            regions.append(ImageTextRegion(text: candidate.string, bounds: observation.boundingBox))
        }
        return RecognizedImageText(lines.joined(separator: "\n"), regions: regions)
    }
}

// OCR, transliteration, and its derived cache all share one background queue, never the search actor.
final class ImageTextService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.clipshelf.image-text", qos: .background)
    private let cacheURL: URL
    private let recognize: (@Sendable (Data) throws -> String)?
    private let cancellationLock = NSLock()
    private var activeRequest: VNRequest?
    private var cancellationRequested = false
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let version = 2

    init(cacheURL: URL, recognize: (@Sendable (Data) throws -> String)? = nil) {
        self.cacheURL = cacheURL; self.recognize = recognize
    }
    deinit { if let db { sqlite3_close_v2(db) } }

    func cancelRecognition() {
        cancellationLock.lock(); cancellationRequested = true; let request = activeRequest; cancellationLock.unlock()
        request?.cancel()
    }
    func interruptRecognition() {
        cancellationLock.lock(); let request = activeRequest; cancellationLock.unlock()
        request?.cancel()
    }
    static func wasInterrupted(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == VNErrorDomain && error.code == VNErrorCode.requestCancelled.rawValue
    }
    func resumeRecognition() { cancellationLock.lock(); cancellationRequested = false; cancellationLock.unlock() }
    private func register(_ request: VNRequest?) {
        cancellationLock.lock(); activeRequest = request; let cancelled = cancellationRequested; cancellationLock.unlock()
        if cancelled { request?.cancel() }
    }
    private func checkCancellation() throws {
        cancellationLock.lock(); let cancelled = cancellationRequested; cancellationLock.unlock()
        if cancelled { throw CancellationError() }
    }

    func cachedTexts() async throws -> [String: RecognizedImageText] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    guard FileManager.default.fileExists(atPath: self.cacheURL.path) else { return [:] }
                    try self.openCache()
                    let query = try self.statement("SELECT fingerprint, result FROM image_text WHERE version = \(Self.version)")
                    defer { sqlite3_finalize(query) }
                    var results: [String: RecognizedImageText] = [:]
                    while true {
                        let step = sqlite3_step(query)
                        if step == SQLITE_DONE { break }
                        guard step == SQLITE_ROW, let key = sqlite3_column_text(query, 0), let bytes = sqlite3_column_blob(query, 1) else { throw self.failure() }
                        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 1)))
                        if let result = try? PropertyListDecoder().decode(RecognizedImageText.self, from: data) {
                            results[String(cString: key)] = result
                        }
                    }
                    return results
                })
            }
        }
    }

    func text(for clip: Clip) async throws -> RecognizedImageText {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try autoreleasepool {
                    try self.checkCancellation()
                    try self.openCache()
                    if let cached = try self.cached(clip.fingerprint) { return cached }
                    // Match the primary image used to identify the card during capture.
                    let representations = clip.items.flatMap { $0 }
                    guard clip.kind == .image,
                          let data = representations.first(where: { $0.type == "public.png" || $0.type == "public.tiff" })?.data
                    else { throw CocoaError(.fileReadCorruptFile) }
                    let result: RecognizedImageText
                    if let recognize = self.recognize { result = RecognizedImageText(try recognize(data)) }
                    else { result = try LocalImageOCR.recognizeText(data, register: self.register) }
                    try self.checkCancellation()
                    try self.store(result, fingerprint: clip.fingerprint)
                    return result
                } })
            }
        }
    }
    func prune(keeping fingerprints: Set<String>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result {
                    guard self.db != nil || FileManager.default.fileExists(atPath: self.cacheURL.path) else { return }
                    try self.openCache()
                    let keys = try self.statement("SELECT fingerprint FROM image_text")
                    defer { sqlite3_finalize(keys) }
                    var obsolete: [String] = []
                    while true {
                        let step = sqlite3_step(keys)
                        if step == SQLITE_DONE { break }
                        guard step == SQLITE_ROW, let value = sqlite3_column_text(keys, 0) else { throw self.failure() }
                        let key = String(cString: value)
                        if !fingerprints.contains(key) { obsolete.append(key) }
                    }
                    let remove = try self.statement("DELETE FROM image_text WHERE fingerprint = ?")
                    defer { sqlite3_finalize(remove) }
                    for key in obsolete {
                        sqlite3_reset(remove); sqlite3_clear_bindings(remove)
                        try self.bind(key, to: remove)
                        guard sqlite3_step(remove) == SQLITE_DONE else { throw self.failure() }
                    }
                })
            }
        }
    }
    private func failure() -> NSError {
        NSError(domain: "ClipShelf.ImageText", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开图片文字缓存。"])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure() }
        return value
    }
    private func bind(_ fingerprint: String, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, 1, fingerprint, -1, transient) == SQLITE_OK else { throw failure() }
    }
    private func openCache() throws {
        guard db == nil else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: cacheURL.path) {
            guard manager.createFile(atPath: cacheURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        do {
            guard sqlite3_open_v2(cacheURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
            sqlite3_busy_timeout(db, 1000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS image_text (fingerprint TEXT PRIMARY KEY NOT NULL, version INTEGER NOT NULL, result BLOB NOT NULL)")
        } catch {
            if let db { sqlite3_close_v2(db) }; db = nil
            throw error
        }
    }
    private func cached(_ fingerprint: String) throws -> RecognizedImageText? {
        let query = try statement("SELECT result FROM image_text WHERE fingerprint = ? AND version = \(Self.version)")
        defer { sqlite3_finalize(query) }
        try bind(fingerprint, to: query)
        let step = sqlite3_step(query)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw failure() }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
        // A damaged derived result can be regenerated without touching the original image.
        return try? PropertyListDecoder().decode(RecognizedImageText.self, from: data)
    }
    private func store(_ result: RecognizedImageText, fingerprint: String) throws {
        let query = try statement("INSERT INTO image_text(fingerprint, version, result) VALUES(?, \(Self.version), ?) ON CONFLICT(fingerprint) DO UPDATE SET version=excluded.version, result=excluded.result")
        defer { sqlite3_finalize(query) }
        try bind(fingerprint, to: query)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(result)
        let bound = data.withUnsafeBytes { sqlite3_bind_blob64(query, 2, $0.baseAddress, UInt64($0.count), transient) }
        guard bound == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }
}
