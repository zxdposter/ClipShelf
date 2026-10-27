import AppKit

// The app bundle exposes both commands through symlinks to its executable.
enum FileCopyCommand {
    static let usage = "Usage: fcp [--] FILE...\nCopy files or folders to the macOS clipboard for pasting in Finder."

    static let textUsage = "Usage: cpx [--] FILE\nCopy the entire contents of one text file to the macOS clipboard."

    static func fileURLs(_ arguments: [String], command: String = "fcp", currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> [URL] {
        var paths = arguments
        if paths.first == "--" { paths.removeFirst() }
        else if let option = paths.first(where: { $0.hasPrefix("-") }) {
            throw CommandError("Unknown option: \(option). Use '\(command) -- FILE...' for paths beginning with '-'.")
        }
        guard !paths.isEmpty else { throw CommandError(command == "cpx" ? textUsage : usage) }
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        return try paths.map { path in
            guard !path.isEmpty else { throw CommandError("File path must not be empty.") }
            let url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CommandError("File does not exist: \(path)")
            }
            return url
        }
    }

    static func copy(_ arguments: [String], to pasteboard: NSPasteboard) throws {
        let urls = try fileURLs(arguments)
        // Store concrete bytes so file references outlive this short-lived command.
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            throw CommandError("Could not write files to the clipboard.")
        }
    }

    static func copyText(_ arguments: [String], to pasteboard: NSPasteboard) throws {
        let urls = try fileURLs(arguments, command: "cpx")
        guard urls.count == 1 else { throw CommandError(textUsage) }
        let url = urls[0]
        guard (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CommandError("Expected a regular text file: \(url.path)")
        }
        let text: String
        do { text = try String(contentsOf: url) }
        catch { throw CommandError("Could not read text from file: \(url.path)") }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw CommandError("Could not write text to the clipboard.")
        }
    }

    static func run(_ arguments: [String], textContents: Bool = false) -> Int32 {
        let command = textContents ? "cpx" : "fcp"
        if arguments == ["--help"] || arguments == ["-h"] {
            print(textContents ? textUsage : usage)
            return 0
        }
        do {
            if textContents { try copyText(arguments, to: .general) }
            else { try copy(arguments, to: .general) }
            print(textContents ? "File text copied to the clipboard." : "Files copied to the clipboard.")
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(command): \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private struct CommandError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
