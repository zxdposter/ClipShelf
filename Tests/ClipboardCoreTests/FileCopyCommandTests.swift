import AppKit
import Testing
@testable import ClipShelf

struct FileCopyCommandTests {
    @Test func resolvesPathsAndRejectsMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["中文 file.txt", "-draft"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let urls = try FileCopyCommand.fileURLs(["--", "中文 file.txt", "-draft", "."], currentDirectory: directory.path)
        #expect(urls.map(\.path) == [directory.appendingPathComponent("中文 file.txt").path, directory.appendingPathComponent("-draft").path, directory.path])
        #expect(throws: (any Error).self) { try FileCopyCommand.fileURLs([], currentDirectory: directory.path) }
        #expect(throws: (any Error).self) { try FileCopyCommand.fileURLs(["-draft"], currentDirectory: directory.path) }
        #expect(throws: (any Error).self) { try FileCopyCommand.fileURLs(["中文 file.txt", "missing"], currentDirectory: directory.path) }
        #expect(throws: (any Error).self) { try FileCopyCommand.fileURLs([""], currentDirectory: directory.path) }
    }

    @Test @MainActor func copiesFileURLsAndInvalidInputPreservesClipboard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("中文 file.txt")
        try Data("test".utf8).write(to: file)
        let board = NSPasteboard(name: .init("ClipShelf-fcp-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("keep me", forType: .string)
        #expect(throws: (any Error).self) { try FileCopyCommand.copy([file.path, directory.appendingPathComponent("missing").path], to: board) }
        #expect(board.string(forType: .string) == "keep me")
        try FileCopyCommand.copy([file.path, directory.path], to: board)
        let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls?.map(\.path) == [file.path, directory.path])
        #expect(try String(contentsOf: file, encoding: .utf8) == "test")
    }
    @Test @MainActor func copiesEntireTextWithSystemEncodingDetection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: .init("ClipShelf-cpx-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let text = String(repeating: "完整文本 Full text\r\n第二行\n", count: 10_000)
        for encoding in [String.Encoding.utf8, .utf16] {
            let file = directory.appendingPathComponent("中文 file-\(encoding.rawValue).txt")
            try text.write(to: file, atomically: true, encoding: encoding)
            try FileCopyCommand.copyText([file.path], to: board)
            #expect(board.string(forType: .string) == text)
            #expect(try String(contentsOf: file, encoding: encoding) == text)
        }
        let empty = directory.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        try FileCopyCommand.copyText([empty.path], to: board)
        #expect(board.string(forType: .string) == "")
    }

    @Test @MainActor func invalidTextInputPreservesClipboardAndUsesEnglishErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.txt")
        try Data("test".utf8).write(to: file)
        let board = NSPasteboard(name: .init("ClipShelf-cpx-errors-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("keep me", forType: .string)
        for arguments in [[], [directory.path], [file.path, file.path], ["--unknown"], [directory.appendingPathComponent("missing").path]] {
            do {
                try FileCopyCommand.copyText(arguments, to: board)
                Issue.record("Expected invalid input to fail")
            } catch {
                #expect(error.localizedDescription.unicodeScalars.allSatisfy { $0.isASCII })
            }
            #expect(board.string(forType: .string) == "keep me")
        }
    }

}
