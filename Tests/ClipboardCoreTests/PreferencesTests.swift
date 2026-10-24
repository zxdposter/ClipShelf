import Foundation
import AppKit
import Testing
@testable import ClipboardCore
@testable import ClipShelf

@MainActor
func isolatedPreferences() -> Preferences {
    Preferences(defaults: UserDefaults(suiteName: "ClipShelf.tests.\(UUID().uuidString)")!)
}

struct PreferencesTests {
    @Test @MainActor func settingsPersistAndValidateStoredValues() throws {
        let suite = "ClipShelf.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.captures(.text))
        #expect(preferences.appearance == .system)
        #expect(AppAppearance.system.next == .light)
        #expect(AppAppearance.light.next == .dark)
        #expect(AppAppearance.dark.next == .system)
        #expect(AppAppearance.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
        #expect(preferences.appearance.nativeAppearance == nil)
        preferences.appearance = .dark
        #expect(preferences.appearance.nativeAppearance?.name == .darkAqua)
        preferences.textEnabled = false
        preferences.imageEnabled = false
        defaults.set(50, forKey: "historyLimit")
        preferences.shortcut = .optionCommandV
        preferences.excludedApps = " com.example.secret \ncom.example.mail\n"
        let restored = Preferences(defaults: defaults)
        #expect(restored.appearance == .dark)
        #expect(!restored.captures(.text) && !restored.captures(.image))
        #expect(restored.captures(.link) && restored.captures(.files))
        #expect(restored.shortcut == .optionCommandV)
        #expect(restored.excludes("com.example.secret") && restored.excludes("com.example.mail"))
        #expect(!restored.excludes("") && !restored.excludes("com.example.secret.extra"))
        preferences.appearance = .light
        #expect(Preferences(defaults: defaults).appearance.nativeAppearance?.name == .aqua)
        defaults.set("invalid", forKey: "appAppearance")
        defaults.set(999_999, forKey: "historyLimit")
        defaults.set("invalid", forKey: "shortcut")
        let invalid = Preferences(defaults: defaults)
        #expect(invalid.appearance == .system)
        #expect(invalid.shortcut == .shiftCommandV)
    }
    @Test @MainActor func disabledContentDoesNotEnterHistory() async throws {
        let suite = "ClipShelf.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let preferences = Preferences(defaults: defaults)
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: preferences)
        defer { _ = model.flushStorage() }
        preferences.textEnabled = false
        board.setString("disabled text", forType: .string)
        await model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.isEmpty)
        board.clearContents(); board.setString("https://example.com", forType: .string)
        await model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.first?.kind == .link)
        preferences.textEnabled = true
        board.clearContents(); board.setString("enabled text", forType: .string)
        await model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.count == 2)
        defaults.set(50, forKey: "historyLimit")
        model.history = History(clips: (0..<250).map { index in
            let text = "existing \(index)"
            return Clip(kind: .text, text: text, sourceName: "test", sourceBundle: "",
                        items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]], identity: Data(text.utf8))
        })
        board.clearContents(); board.setString("beyond old limit", forType: .string)
        await model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.count == 251)
        #expect(model.flushStorage())
        #expect(try History.load(from: directory.appendingPathComponent("history.plist")).clips.count == 251)
    }
    @Test func clearPreservesPinboards() throws {
        var history = History()
        let board = try #require(history.boards.first?.id)
        for index in 0..<60 {
            let text = "item \(index)"
            let clip = Clip(kind: .text, text: text, sourceName: "test", sourceBundle: "",
                            items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]], identity: Data(text.utf8))
            try history.insert(clip)
            if index == 0 { history.addToBoard(clipID: clip.id, boardID: board) }
        }
        #expect(history.clips.count == 60)
        #expect(history.clips.contains(where: { $0.text == "item 0" }))
        history.removeUnpinned()
        #expect(history.clips.count == 1 && history.clips.first?.text == "item 0")
        #expect(history.boards.first?.clipIDs == history.clips.map(\.id))
    }
}
