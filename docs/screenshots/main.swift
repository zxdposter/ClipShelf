import AppKit
import SwiftUI
import ClipboardCore

// This executable never orders a window onscreen, activates an app, or uses the general pasteboard.
@MainActor final class ScreenshotDelegate: NSObject, NSApplicationDelegate {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let domain = "local.clipshelf.docs.\(UUID().uuidString)"
    let board = NSPasteboard(name: .init("ClipShelf-docs-\(UUID().uuidString)"))
    var chinese = false
    var model: ClipboardModel!
    var imageClip: Clip!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for language in [AppLanguage.english, .chinese] { try await render(language) }
                print("Rendered isolated screenshots without activating or displaying a window.")
                cleanup(); NSApp.terminate(nil)
            } catch {
                fputs("Screenshot generation failed: \(error)\n", stderr)
                cleanup(); exit(1)
            }
        }
    }
    func cleanup() {
        board.releaseGlobally()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: temporary)
    }
    func text(_ value: String, app: String, bundle: String) -> Clip {
        Clip(kind: .text, text: value, sourceName: app, sourceBundle: bundle,
             items: [[Representation(type: "public.utf8-plain-text", data: Data(value.utf8))]], identity: Data(value.utf8))
    }
    func fixture() throws -> History {
        let artwork = NSImage(size: NSSize(width: 1000, height: 640), flipped: false) { rect in
            NSColor(srgbRed: 0.96, green: 0.94, blue: 0.88, alpha: 1).setFill(); rect.fill()
            NSColor(srgbRed: 0.18, green: 0.32, blue: 0.34, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 50, y: 45, width: 900, height: 550), xRadius: 24, yRadius: 24).fill()
            let lines = ["中文搜索 · Chinese search", "设计灵感 / Design notes", "Keep good ideas close.", "LOCAL NOTES   /   2026"]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 90, y: 470 - index * 105), withAttributes: [
                    .font: NSFont.systemFont(ofSize: index == 0 ? 46 : 35, weight: index == 0 ? .semibold : .regular),
                    .foregroundColor: NSColor.white
                ])
            }
            return true
        }
        guard let tiff = artwork.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadCorruptFile) }
        imageClip = Clip(kind: .image, text: chinese ? "设计灵感.png" : "Design notes.png", sourceName: chinese ? "预览" : "Preview",
                         sourceBundle: "com.apple.Preview", items: [[Representation(type: "public.png", data: png)]], identity: png)
        let notes = text(chinese ? "周末计划\n\n✓ 找一家新的咖啡馆\n✓ 整理旅行照片\n✓ 留点时间给好点子" : "Weekend plans\n\n✓ Find a new coffee spot\n✓ Sort the travel photos\n✓ Make room for good ideas", app: chinese ? "备忘录" : "Notes", bundle: "com.apple.Notes")
        let travel = text(chinese ? "京都 · 周末指南\n\n沿河散步，找一家小店。\n书店、庭院和咖啡馆。" : "Kyoto · Weekend guide\n\nTake the scenic route.\nFind a bookshop and a quiet cafe.", app: "Safari", bundle: "com.apple.Safari")
        let reply = text(chinese ? "常用回复\n\n谢谢你的分享！\n期待一起讨论下一步。" : "A thoughtful reply\n\nThanks for sharing!\nLooking forward to the next step.", app: chinese ? "邮件" : "Mail", bundle: "com.apple.mail")
        let pinyin = text("中文搜索\n\n" + (chinese ? "输入中文、全拼或首字母，\n都能找到保存的内容。" : "Find Chinese text with\nfull pinyin or initials."), app: chinese ? "备忘录" : "Notes", bundle: "com.apple.Notes")
        var result = History(clips: [notes, travel, imageClip, reply, pinyin], boards: [
            Pinboard(name: chinese ? "灵感" : "Ideas", color: 1), Pinboard(name: chinese ? "旅行" : "Travel", color: 2),
            Pinboard(name: chinese ? "常用回复" : "Replies", color: 3)
        ])
        for clip in [notes, imageClip!] { result.addToBoard(clipID: clip.id, boardID: result.boards[0].id) }
        result.addToBoard(clipID: travel.id, boardID: result.boards[1].id)
        result.addToBoard(clipID: reply.id, boardID: result.boards[2].id)
        return result
    }
    func shelf() -> some View {
        ShelfView(model: model, dismiss: {}, openSettings: {}, enableCapture: {}, paste: { _, _ in })
    }
    func shot<V: View>(_ name: String, _ view: V, width: CGFloat = 1180, height: CGFloat = 310, dark: Bool = false) async throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width, height: height).background(ShelfDesign.canvas))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = appearance
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { throw CocoaError(.fileWriteUnknown) }
        try jpeg.write(to: directory.appendingPathComponent("\(name)-\(chinese ? "zh" : "en").jpg"))
        print("Rendered \(name)-\(chinese ? "zh" : "en").jpg (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
        window.close()
    }
    func render(_ language: AppLanguage) async throws {
        chinese = language == .chinese
        AppLocalization.shared.language = language
        let defaults = UserDefaults(suiteName: domain)!
        let preferences = Preferences(defaults: defaults)
        preferences.language = language; preferences.linkPreviews = false; preferences.retention = .forever
        preferences.appearance = .light
        let storage = temporary.appendingPathComponent("\(language.rawValue)/history.plist")
        model = ClipboardModel(pasteboard: board, storageURL: storage, preferences: preferences, searchIndex: MemorySearchIndex())
        model.history = try fixture(); model.resetSelection()
        await model.waitForImageText()
        guard model.imageTextError == nil else { throw CocoaError(.featureUnsupported) }
        try await shot("clipboard", shelf())
        preferences.appearance = .dark
        try await shot("clipboard-dark", shelf(), dark: true)
        preferences.appearance = .light
        model.searchShown = true; model.query = "zhongwen"; await model.waitForSearch()
        try await shot("search-pinyin", shelf())
        model.query = "zw"; await model.waitForSearch()
        try await shot("search-initials", shelf())
        model.filter = .image; model.query = "中文"; await model.waitForSearch()
        guard !model.imageTextHighlights(for: imageClip).isEmpty else { throw CocoaError(.featureUnsupported) }
        try await shot("image-search", shelf())
        try await shot("image-preview", ClipPreview(clip: imageClip, model: model, close: {}), width: 660, height: 450)
        model.clearSearch(); model.searchShown = true
        model.selectedSourceIDs = Set(model.sourceApps.prefix(3).map(\.id))
        try await shot("source-filters", shelf())
        model.clearSearch(); model.searchShown = false; model.selectedBoardID = model.history.boards[0].id; model.resetSelection()
        model.selection.selectAll(in: model.visible.map(\.id))
        try await shot("collections", shelf())
        model.selectedBoardID = nil; model.resetSelection(); model.updateQuickPasteModifier(.command)
        try await Task.sleep(for: .milliseconds(180))
        try await shot("quick-paste", shelf())
        model.updateQuickPasteModifier([])
        model.stackPasteAvailable = true; model.stackIDs = Array(model.history.clips.prefix(3).map(\.id)); model.startStack(includeSelection: false)
        try await shot("sequential-paste", StackView(model: model, openSettings: {}, finish: {}), width: 360, height: 440)
        try await shot("settings", SettingsView(model: model, preferences: preferences, changeShortcut: { _, _ in }, recordingChanged: { _ in }, enableCapture: {}), width: 820, height: 740)
        let keyboardState = SettingsState(); keyboardState.page = .shortcuts
        try await shot("settings-shortcuts", SettingsView(model: model, preferences: preferences, changeShortcut: { _, _ in }, recordingChanged: { _ in }, enableCapture: {}, state: keyboardState), width: 820, height: 820)
        guard await model.finishPendingStorage() else { throw CocoaError(.fileWriteUnknown) }
        model = nil
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = ScreenshotDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
