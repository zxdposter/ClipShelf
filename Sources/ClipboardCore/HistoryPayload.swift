import Foundation
import Darwin

struct StoredPayload: Codable {
    struct Bytes: Codable {
        let type: String
        let data: Data?
        let file: String?
        let count: Int

        init(_ representation: Representation, directory: URL) throws {
            type = representation.type
            let original = representation.data
            count = original.count
            if count < 256 * 1024 {
                data = original; file = nil
            } else {
                data = nil
                let manager = FileManager.default
                if let existing = representation.file, existing.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
                   manager.fileExists(atPath: existing.path) {
                    file = existing.lastPathComponent
                } else {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let destination = directory.appendingPathComponent(UUID().uuidString)
                    try original.write(to: destination, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    let handle = try FileHandle(forWritingTo: destination)
                    defer { try? handle.close() }
                    try handle.synchronize()
                    try representation.map(to: destination)
                    file = destination.lastPathComponent
                }
            }
        }

        func representation(in directory: URL) throws -> Representation {
            if let data {
                guard file == nil, data.count == count else { throw HistoryError.invalidArchive }
                return Representation(type: type, data: data)
            }
            guard let file, UUID(uuidString: file)?.uuidString == file, count >= 256 * 1024 else { throw HistoryError.invalidArchive }
            let url = directory.appendingPathComponent(file)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == count else { throw HistoryError.invalidArchive }
            let mapped = try Data(contentsOf: url, options: .alwaysMapped)
            guard mapped.count == count else { throw HistoryError.invalidArchive }
            return Representation(type: type, data: mapped, file: url)
        }
    }

    let text: String
    let items: [[Bytes]]
    init(_ payload: Clip.Payload, directory: URL) throws {
        text = payload.text
        items = try payload.items.map { try $0.map { try Bytes($0, directory: directory) } }
    }
    func payload(in directory: URL) throws -> Clip.Payload {
        Clip.Payload(text: text, items: try items.map { try $0.map { try $0.representation(in: directory) } })
    }
    var files: [String] { items.flatMap { $0.compactMap(\.file) } }
}
