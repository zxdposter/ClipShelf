import Foundation
import AppKit
import Carbon
import Testing
@testable import ClipboardCore
@testable import ClipShelf

struct OriginalSettingsTests {
    @Test @MainActor func mcpCredentialsPersistAndRevokeIndependently() throws {
        let suite = "ClipShelf-MCP-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.mcpEnabled = true
        preferences.addMCPClient(name: "Harness", token: "first")
        preferences.addMCPClient(name: "Other", token: "second")
        #expect(Preferences(defaults: defaults).mcpClients.count == 2)
        #expect(MCPService.credentialAuthorized("first", defaults: defaults))
        #expect(!MCPService.credentialAuthorized("forged", defaults: defaults))
        preferences.revokeMCPClient(MCPService.credentialID("first"))
        #expect(!MCPService.credentialAuthorized("first", defaults: defaults))
        #expect(MCPService.credentialAuthorized("second", defaults: defaults))
        preferences.mcpEnabled = false
        #expect(!MCPService.credentialAuthorized("second", defaults: defaults))
    }
    private func clip(_ text: String, date: Date = Date()) -> Clip {
        Clip(kind: .text, text: text, sourceName: "test", sourceBundle: "test.app",
             items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8)), Representation(type: "public.rtf", data: Data("{\\rtf1 test}".utf8))]], identity: Data(text.utf8), copiedAt: date)
    }
    @Test func mcpReadsShortRequestsBeforeClientClosesInput() throws {
        let pipe = Pipe()
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: request)
        let writer = pipe.fileHandleForWriting
        // Unblock a regression instead of hanging the test suite indefinitely.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { try? writer.close() }
        let start = Date()
        #expect(MCPService.readChunk(from: pipe.fileHandleForReading) == request)
        #expect(Date().timeIntervalSince(start) < 0.5)
        try pipe.fileHandleForReading.close()
    }
    @Test func retentionExpiresOnlyUnpinnedItems() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = clip("old", date: now.addingTimeInterval(-100_000))
        let pinned = clip("pinned", date: now.addingTimeInterval(-200_000))
        let recent = clip("recent", date: now.addingTimeInterval(-100))
        var history = History()
        for item in [old, pinned, recent] { try history.insert(item) }
        history.addToBoard(clipID: pinned.id, boardID: try #require(history.boards.first?.id))
        history.prune(before: try #require(RetentionPeriod.day.cutoff(now: now)))
        #expect(Set(history.clips.map(\.id)) == [pinned.id, recent.id])
        #expect(RetentionPeriod.forever.cutoff(now: now) == nil)
        let monthAge = now.timeIntervalSince(try #require(RetentionPeriod.month.cutoff(now: now)))
        #expect(monthAge > 27 * 86400 && monthAge < 32 * 86400)
    }
    @Test func recordedBindingsEncodeModifiersAndRejectUnmodifiedGlobalKeys() throws {
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), key: "B")
        #expect(binding.title == "⌃⌥⇧⌘B" && binding.validGlobal)
        #expect(KeyBinding.carbonModifiers([.command, .shift, .option, .control, .capsLock]) == binding.modifiers)
        #expect(!KeyBinding(keyCode: 11, modifiers: UInt32(shiftKey), key: "B").validGlobal)
        let restored = try JSONDecoder().decode(KeyBinding.self, from: JSONEncoder().encode(binding))
        #expect(restored == binding)
    }
    @Test @MainActor func preferencesStoreOriginalOptionsAndCanDisableBindings() throws {
        let suite = "ClipShelf.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.ignoreConfidential && preferences.ignoreTransient)
        #expect(!preferences.linkPreviews && !preferences.mcpEnabled)
        #expect(preferences.quickPasteFromVisibleCards)
        preferences.quickPasteFromVisibleCards = false
        #expect(preferences.excludes("com.apple.Passwords"))
        preferences.retention = .week; preferences.pasteDestination = .clipboard
        preferences.alwaysPlainText = true; preferences.soundEnabled = false
        preferences.ignoreTransient = false; preferences.showInScreenSharing = false
        preferences.setBinding(nil, for: .activate)
        preferences.setBinding(ShortcutAction.nextBoard.defaultBinding, for: .previousBoard)
        preferences.mcpEnabled = true
        let firstEpoch = defaults.string(forKey: "mcpSessionEpoch")
        preferences.mcpEnabled = false
        #expect(firstEpoch != defaults.string(forKey: "mcpSessionEpoch"))
        let restored = Preferences(defaults: defaults)
        #expect(!restored.quickPasteFromVisibleCards)
        #expect(restored.retention == .week && restored.pasteDestination == .clipboard)
        #expect(restored.alwaysPlainText && !restored.soundEnabled && !restored.ignoreTransient && !restored.showInScreenSharing)
        #expect(restored.binding(for: .activate) == nil)
        #expect(restored.binding(for: .previousBoard) == ShortcutAction.nextBoard.defaultBinding)
    }
    @Test @MainActor func privacyFlagsAndPlainTextCopyAffectRealRepresentations() throws {
        let suite = "ClipShelf.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.releaseGlobally() }
        let preferences = Preferences(defaults: defaults)
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: preferences)
        let concealed = NSPasteboardItem(); concealed.setString("private sample", forType: .string)
        concealed.setString("1", forType: .init("org.nspasteboard.ConcealedType"))
        board.writeObjects([concealed]); model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.isEmpty)
        preferences.ignoreConfidential = false
        model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.count == 1)
        let credential = NSPasteboardItem()
        credential.setString("test credential", forType: .string)
        credential.setString("1", forType: .init("local.clipshelf.credential"))
        board.clearContents(); board.writeObjects([credential])
        model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.count == 1)
        let item = clip("plain")
        #expect(model.copy([item], plainText: true))
        #expect(board.string(forType: .string) == "plain")
        #expect(board.data(forType: .rtf) == nil)
        #expect(model.copy(item))
        #expect(board.data(forType: .rtf) != nil)
        let image = Clip(kind: .image, text: "图片", sourceName: "test", sourceBundle: "", items: [[Representation(type: "public.png", data: Data([1, 2, 3]))]], identity: Data([1, 2, 3]))
        #expect(model.copy([image], plainText: true))
        #expect(board.data(forType: .png) == Data([1, 2, 3]))
    }
    @Test @MainActor func stackAndBoardNavigationUseStableItems() throws {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.resetSelection(); let first = try #require(model.visible.first)
        model.startStack()
        #expect(model.stackClips.map(\.id) == [first.id])
        model.stackIDs.removeFirst(); #expect(model.stackClips.isEmpty)
        #expect(!model.visible.isEmpty)
        model.stackMode = false
        model.advanceBoard(1); #expect(model.selectedBoardID == model.history.boards.first?.id)
        model.advanceBoard(1); #expect(model.selectedBoardID == nil)
        model.advanceBoard(-1); #expect(model.selectedBoardID == model.history.boards.last?.id)
    }
    @Test @MainActor func stackPasteConsumesOnlyQueueAndPreservesHistory() throws {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        let ids = model.history.clips.map(\.id)
        model.resetSelection()
        model.startStack(includeSelection: false)
        #expect(model.stackIDs.isEmpty)
        #expect(!model.prepareStackPaste())
        model.stackIDs = Array(ids.prefix(2))
        model.stackIDs.reverse()
        #expect(model.prepareStackPaste())
        #expect(model.copiedID == ids[1])
        #expect(model.stackIDs == [ids[0]])
        #expect(model.prepareStackPaste())
        #expect(model.copiedID == ids[0])
        #expect(!model.prepareStackPaste())
        #expect(model.history.clips.map(\.id) == ids)
        model.stackMode = false
        model.stackIDs = [ids[0]]
        #expect(!model.prepareStackPaste())
        #expect(model.stackIDs == [ids[0]])
    }
    @Test func mcpDeniesUnapprovedClientsAndOmitsBinaryData() throws {
        let item = clip("private clipboard")
        let history = History(clips: [item])
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "search_items", "arguments": ["query": "private", "limit": 1]]]
        let denied = try #require(MCPService.response(request, history: history, authorized: false))
        #expect(denied["result"] == nil && denied["error"] != nil)
        let response = try #require(MCPService.response(request, history: history, authorized: true))
        let result = try #require(response["result"] as? [String: Any])
        let contents = try #require(result["content"] as? [[String: Any]])
        let text = try #require(contents.first?["text"] as? String)
        #expect(text.contains("private clipboard") && text.contains(item.id.uuidString))
        #expect(!text.contains("rtf") && !text.contains("representations"))
        let invalid: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "search_items", "arguments": ["limit": 0]]]
        #expect(MCPService.response(invalid, history: history, authorized: true)?["error"] != nil)
        #expect(MCPService.response(["method": "notifications/initialized"], history: history, authorized: true) == nil)
    }
}
