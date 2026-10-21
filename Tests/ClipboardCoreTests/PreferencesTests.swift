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
        #expect(preferences.historyLimit == 200 && preferences.captures(.text))
        #expect(preferences.appearance == .system)
        #expect(preferences.appearance.nativeAppearance == nil)
        preferences.appearance = .dark
        #expect(preferences.appearance.nativeAppearance?.name == .darkAqua)
        preferences.textEnabled = false
        preferences.imageEnabled = false
        preferences.historyLimit = 50
        preferences.shortcut = .optionCommandV
        preferences.excludedApps = " com.example.secret \ncom.example.mail\n"
        let restored = Preferences(defaults: defaults)
        #expect(restored.appearance == .dark)
        #expect(!restored.captures(.text) && !restored.captures(.image))
        #expect(restored.captures(.link) && restored.captures(.files))
        #expect(restored.historyLimit == 50 && restored.shortcut == .optionCommandV)
        #expect(restored.excludes("com.example.secret") && restored.excludes("com.example.mail"))
        #expect(!restored.excludes("") && !restored.excludes("com.example.secret.extra"))
        preferences.appearance = .light
        #expect(Preferences(defaults: defaults).appearance.nativeAppearance?.name == .aqua)
        defaults.set("invalid", forKey: "appAppearance")
        defaults.set(999_999, forKey: "historyLimit")
        defaults.set("invalid", forKey: "shortcut")
        let invalid = Preferences(defaults: defaults)
        #expect(invalid.appearance == .system)
        #expect(invalid.historyLimit == 200 && invalid.shortcut == .shiftCommandV)
    }
    @Test @MainActor func disabledContentDoesNotEnterHistory() throws {
        let suite = "ClipShelf.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let preferences = Preferences(defaults: defaults)
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: preferences)
        preferences.textEnabled = false
        board.setString("disabled text", forType: .string)
        model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.isEmpty)
        board.clearContents(); board.setString("https://example.com", forType: .string)
        model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.first?.kind == .link)
        preferences.textEnabled = true
        board.clearContents(); board.setString("enabled text", forType: .string)
        model.capture(expectedChange: board.changeCount)
        #expect(model.history.clips.count == 2)
    }
    @Test func reducedCapacityAndClearPreservePinboards() throws {
        var history = History()
        let board = try #require(history.boards.first?.id)
        for index in 0..<60 {
            let text = "item \(index)"
            let clip = Clip(kind: .text, text: text, sourceName: "test", sourceBundle: "",
                            items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]], identity: Data(text.utf8))
            try history.insert(clip)
            if index == 0 { history.addToBoard(clipID: clip.id, boardID: board) }
        }
        try history.trim(to: 50)
        #expect(history.clips.count == 50)
        #expect(history.clips.contains(where: { $0.text == "item 0" }))
        history.removeUnpinned()
        #expect(history.clips.count == 1 && history.clips.first?.text == "item 0")
        #expect(history.boards.first?.clipIDs == history.clips.map(\.id))
        #expect(throws: HistoryError.self) { try history.trim(to: 0) }
    }
}
