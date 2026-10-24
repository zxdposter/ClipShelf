import AppKit
import SwiftUI
import ClipboardCore

@MainActor
final class SearchInput: ObservableObject {
    @Published var text = ""
}

@MainActor
final class ClipboardModel: ObservableObject {
    @Published var history = History() { didSet { refreshSourceApps(); scheduleSearch(indexChanged: true); scheduleImageTextRecognition() } }
    let searchInput = SearchInput()
    var query: String {
        get { searchInput.text }
        set {
            guard newValue != searchInput.text else { return }
            noteImageTextInteraction()
            searchInput.text = newValue
            if sourceSuggestionIndex != nil { sourceSuggestionIndex = nil }
            scheduleSearch()
        }
    }
    @Published private(set) var searchMatches = Set<UUID>()
    @Published private(set) var searchPending = false
    @Published private(set) var hasSearchResults = false
    @Published private(set) var imageSearchHighlights: [UUID: [CGRect]] = [:]
    private let searchIndex: any ClipboardSearchIndex
    private let fallbackIndex = MemorySearchIndex()
    private var scheduledQuery = ""
    private var indexTask: Task<Bool, Never>?
    private var indexRevision = 0
    private var readyRevision: Int?
    private var searchTask: Task<Void, Never>?
    private var searchRevision = 0
    private(set) var searchError: String?

    private func searchDocuments() -> [SearchDocument] {
        history.clips.map { SearchDocument($0, imageText: imageTexts[$0.fingerprint]) }
    }
    private func scheduleSearch(indexChanged: Bool = false, preservingSelection: Bool = false) {
        guard !locked else { return }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard indexChanged || value != scheduledQuery else { return }
        scheduledQuery = value
        searchRevision += 1
        let revision = searchRevision
        searchTask?.cancel()
        if indexChanged {
            let snapshot = searchDocuments()
            indexRevision += 1
            let target = indexRevision
            let previous = indexTask
            let index = searchIndex
            indexTask = Task(priority: .utility) { [weak self] in
                _ = await previous?.value
                let success: Bool
                do { try await index.synchronize(snapshot); success = true }
                catch { success = false }
                if let self, self.indexRevision == target { self.readyRevision = success ? target : nil }
                return success
            }
        }
        guard !value.isEmpty else {
            if !imageSearchHighlights.isEmpty { imageSearchHighlights = [:] }
            if hasSearchResults { hasSearchResults = false }
            if searchPending { searchPending = false }
            if !searchMatches.isEmpty { searchMatches = [] }
            if !indexChanged { resetSelection() }
            return
        }
        if !preservingSelection && !searchPending { searchPending = true }
        let index = searchIndex
        searchTask = Task(priority: .userInitiated) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                guard let self, self.searchRevision == revision else { return }
                var indexed = self.readyRevision == self.indexRevision
                // The local index is already building; don't transliterate the same history twice on cold start.
                if !indexed, index is MemorySearchIndex {
                    indexed = await self.indexTask?.value == true
                    try Task.checkCancellation()
                }
                let snapshot = self.searchDocuments()
                let ids: Set<UUID>
                var failure = indexed ? nil : "Spotlight index unavailable; background search used"
                if indexed {
                    do { ids = try await index.search(value) }
                    catch {
                        try Task.checkCancellation()
                        failure = "Spotlight query failed; background search used: \(error.localizedDescription)"
                        let fallback = self.fallbackIndex
                        try await fallback.synchronize(snapshot)
                        ids = try await fallback.search(value)
                    }
                } else {
                    let fallback = self.fallbackIndex
                    try await fallback.synchronize(snapshot)
                    ids = try await fallback.search(value)
                }
                guard !Task.isCancelled, self.searchRevision == revision else { return }
                self.searchError = failure
                var highlights: [UUID: [CGRect]] = [:]
                for clip in self.history.clips where clip.kind == .image && ids.contains(clip.id) {
                    let boxes = self.imageTexts[clip.fingerprint]?.matchingRegions(value) ?? []
                    if !boxes.isEmpty { highlights[clip.id] = boxes }
                }
                if self.imageSearchHighlights != highlights { self.imageSearchHighlights = highlights }
                if !self.hasSearchResults { self.hasSearchResults = true }
                if self.searchMatches != ids { self.searchMatches = ids }
                if self.searchPending { self.searchPending = false }
                if preservingSelection {
                    let visible = Set(self.visible.map(\.id))
                    if !self.selection.ids.isSubset(of: visible) || (self.selectedID == nil && !visible.isEmpty) {
                        var next = self.selection
                        next.reset(in: self.visible.map(\.id))
                        if next != self.selection { self.selection = next }
                    }
                } else { self.resetSelection() }
            } catch {
                guard !Task.isCancelled, let self, self.searchRevision == revision else { return }
                self.searchError = error.localizedDescription
                if self.searchPending { self.searchPending = false }
            }
        }
    }
    func waitForSearch() async {
        while let task = searchTask {
            let revision = searchRevision
            await task.value
            if revision == searchRevision { return }
        }
    }
    func waitForIndex() async { _ = await indexTask?.value }
    private let imageTextService: ImageTextService?
    private var imageTexts: [String: RecognizedImageText] = [:]
    func imageTextHighlights(for clip: Clip) -> [CGRect] {
        imageSearchHighlights[clip.id] ?? []
    }
    private var failedImageTexts = Set<String>()
    private var imageTextCacheLoaded = false
    private var imageTextTask: Task<Void, Never>?
    private var imageTextStopped = false
    private var lastImageTextInteraction = ContinuousClock.now
    private(set) var imageTextError: String?

    func noteImageTextInteraction() {
        lastImageTextInteraction = .now
        imageTextService?.interruptRecognition()
    }
    private var imageTextCanUpdate: Bool {
        ContinuousClock.now >= lastImageTextInteraction.advanced(by: .milliseconds(400)) && !searchPending &&
            (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() != true
    }
    private func scheduleImageTextRecognition() {
        guard !locked, !imageTextStopped, imageTextService != nil, imageTextTask == nil else { return }
        let fingerprints = Set(history.clips.filter { $0.kind == .image }.map(\.fingerprint))
        imageTexts = imageTexts.filter { fingerprints.contains($0.key) }
        failedImageTexts.formIntersection(fingerprints)
        imageTextTask = Task(priority: .background) { [weak self] in
            defer {
                self?.imageTextTask = nil
                if let self {
                    let current = Set(self.history.clips.filter { $0.kind == .image }.map(\.fingerprint))
                    self.imageTexts = self.imageTexts.filter { current.contains($0.key) }
                    self.failedImageTexts.formIntersection(current)
                    if self.history.clips.contains(where: {
                        $0.kind == .image && self.imageTexts[$0.fingerprint] == nil && !self.failedImageTexts.contains($0.fingerprint)
                    }) { self.scheduleImageTextRecognition() }
                }
            }
            guard let service = self?.imageTextService else { return }
            if self?.imageTextCacheLoaded == false {
                self?.imageTextCacheLoaded = true
                do {
                    let cached = try await service.cachedTexts()
                    while self?.imageTextCanUpdate == false {
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    }
                    guard !Task.isCancelled, let self else { return }
                    let current = Set(self.history.clips.filter { $0.kind == .image }.map(\.fingerprint))
                    self.imageTexts = cached.filter { current.contains($0.key) }
                    if !self.imageTexts.isEmpty { self.scheduleSearch(indexChanged: true, preservingSelection: true) }
                } catch { self?.imageTextError = error.localizedDescription }
            }
            while !Task.isCancelled {
                while self?.imageTextCanUpdate == false {
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
                guard let clip = self?.history.clips.first(where: {
                    $0.kind == .image && self?.imageTexts[$0.fingerprint] == nil && self?.failedImageTexts.contains($0.fingerprint) == false
                }) else { break }
                do {
                    let result = try await service.text(for: clip)
                    while self?.imageTextCanUpdate == false {
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    }
                    guard !Task.isCancelled else { return }
                    if let self, self.history.clips.contains(where: { $0.kind == .image && $0.fingerprint == clip.fingerprint }) {
                        self.imageTexts[clip.fingerprint] = result
                        self.scheduleSearch(indexChanged: true, preservingSelection: true)
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    if !ImageTextService.wasInterrupted(error) {
                        // shortcut: failed images retry on next launch, not in a CPU-consuming retry loop.
                        self?.failedImageTexts.insert(clip.fingerprint)
                        self?.imageTextError = error.localizedDescription
                    }
                }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            do { try await service.prune(keeping: Set(self.history.clips.filter { $0.kind == .image }.map(\.fingerprint))) }
            catch { self.imageTextError = error.localizedDescription }
        }
    }
    func waitForImageText() async {
        while let task = imageTextTask { await task.value }
        await waitForIndex(); await waitForSearch()
    }
    weak var searchField: NSTextField?
    @Published var searchFocused = false { didSet { if searchFocused { noteImageTextInteraction() } } }
    @Published private(set) var sourceApps: [SourceApplication] = []
    @Published var selectedSourceIDs = Set<String>() {
        didSet {
            if selectedSourceIDs != oldValue {
                if sourceSuggestionIndex != nil { sourceSuggestionIndex = nil }
                refreshSourceApps(); resetSelection()
            }
        }
    }
    @Published private(set) var sourceSuggestionIndex: Int?
    var searchActive: Bool { !query.isEmpty || !selectedSourceIDs.isEmpty || filter != nil }
    var selectedSourceApps: [SourceApplication] { sourceApps.filter { selectedSourceIDs.contains($0.id) } }
    var suggestedSourceApps: [SourceApplication] {
        guard searchFocused, let term = query.split(whereSeparator: \.isWhitespace).last else { return [] }
        return Array(sourceApps.filter { !selectedSourceIDs.contains($0.id) && $0.matches(String(term)) }.prefix(4))
    }
    private func refreshSourceApps() {
        var byID: [String: SourceApplication] = [:]
        for clip in history.clips {
            let id = SourceApplication.id(for: clip)
            guard byID[id] == nil else { continue }
            byID[id] = sourceApps.first(where: { $0.id == id && $0.name == clip.sourceName }) ?? SourceApplication(clip)
        }
        // Keep active tokens when their last item disappears; never silently broaden an active filter.
        for app in sourceApps where selectedSourceIDs.contains(app.id) && byID[app.id] == nil { byID[app.id] = app }
        let apps = byID.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        if sourceApps != apps { sourceApps = apps }
    }
    func toggleSourceApp(_ app: SourceApplication) {
        if selectedSourceIDs.contains(app.id) { selectedSourceIDs.remove(app.id) }
        else { selectedSourceIDs.insert(app.id) }
        searchShown = true
    }
    func selectSourceSuggestion(_ app: SourceApplication) {
        selectedSourceIDs.insert(app.id)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let appRange = text.range(of: app.name, options: [.caseInsensitive, .diacriticInsensitive, .anchored, .backwards])
        let remaining: String
        if let appRange, appRange.lowerBound == text.startIndex || text[text.index(before: appRange.lowerBound)].isWhitespace {
            remaining = String(text[..<appRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            remaining = text.lastIndex(where: \.isWhitespace).map { String(text[..<$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        replaceSearchText(remaining)
        searchShown = true
        searchField?.window?.makeFirstResponder(searchField)
    }
    func moveSourceSuggestion(_ direction: Int) -> Bool {
        let count = suggestedSourceApps.count
        guard count > 0 else { return false }
        let next = sourceSuggestionIndex.map { min(max($0 + direction, 0), count - 1) } ?? (direction > 0 ? 0 : count - 1)
        if sourceSuggestionIndex != next { sourceSuggestionIndex = next }
        return true
    }
    func submitSearch() {
        let suggestions = suggestedSourceApps
        if let index = sourceSuggestionIndex, suggestions.indices.contains(index) {
            selectSourceSuggestion(suggestions[index]); return
        }
        Task { [weak self] in await self?.focusSearchResults() }
    }
    func focusSearchResults() async {
        let editor = searchField?.currentEditor()
        await waitForSearch()
        guard searchShown, let editor, searchField?.currentEditor() === editor else { return }
        searchField?.window?.makeFirstResponder(nil)
        resetSelection()
        selectionScrollID = selectedID
    }
    @Published var filter: ClipKind? { didSet { if filter != oldValue { resetSelection() } } }
    @Published var selectedBoardID: UUID?
    @Published var dropTargetBoardID: UUID?
    @Published var searchShown = false
    @Published var presentationID = UUID()
    @Published var editingBoardID: UUID?
    @Published var namingDroppedBoard = false
    @Published var dropTargetNewBoard = false
    @Published var creatingBoard = false
    @Published var boardNameDraft = L("未命名")
    @Published var boardColorDraft = 1
    private var pendingBoardClipIDs: [UUID] = []
    @Published var paused = false
    @Published var message: String?
    @Published var selection = CardSelection()
    @Published private(set) var selectionScrollID: UUID?
    @Published var previewID: UUID?
    func togglePreview() {
        if previewID != nil { closePreview(); return }
        guard let id = selectedID, selection.ids.contains(id), visible.contains(where: { $0.id == id }) else { return }
        previewID = id
    }
    private(set) var quickPasteHeld = false
    private(set) var quickPasteVisibleRange = 0..<0
    func updateQuickPasteVisibleRange(_ range: Range<Int>) {
        let count = visible.count
        let start = min(max(range.lowerBound, 0), count)
        let end = min(max(range.upperBound, start), count)
        let next = start..<min(end, start + 9)
        guard quickPasteVisibleRange != next else { return }
        noteImageTextInteraction()
        // Scrolling without the modifier must not invalidate every card just to update hidden hints.
        if quickPasteHintsShown && preferences.quickPasteFromVisibleCards { objectWillChange.send() }
        quickPasteVisibleRange = next
    }
    private var quickPasteRange: Range<Int> {
        preferences.quickPasteFromVisibleCards ? quickPasteVisibleRange : 0..<min(9, visible.count)
    }
    @Published private(set) var commandHeld = false
    @Published private(set) var quickPasteHintsShown = false
    private var modifierHintTask: Task<Void, Never>?
    private var hintFlags: NSEvent.ModifierFlags = []
    private var hintModifier: KeyModifier?
    private var suppressModifierHintsUntilReleased = false
    func updateQuickPasteModifier(_ flags: NSEvent.ModifierFlags) {
        let primary: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let modifiers = flags.intersection(primary)
        if modifiers.rawValue.nonzeroBitCount > 1 { suppressModifierHintsUntilReleased = true }
        if modifiers.isEmpty { suppressModifierHintsUntilReleased = false }
        guard modifiers != hintFlags || hintModifier != preferences.quickPasteModifier else { return }
        hintFlags = modifiers
        hintModifier = preferences.quickPasteModifier
        let command = modifiers == .command && !suppressModifierHintsUntilReleased
        let quickHints = modifiers == preferences.quickPasteModifier.flag && !suppressModifierHintsUntilReleased
        let held = modifiers.contains(preferences.quickPasteModifier.flag) && modifiers != primary
        // Shortcut eligibility is immediate; only the visual hints wait for a settled modifier chord.
        if quickPasteHeld != held { quickPasteHeld = held }
        modifierHintTask?.cancel()
        modifierHintTask = nil
        if !command && commandHeld { commandHeld = false }
        if !quickHints && quickPasteHintsShown { quickPasteHintsShown = false }
        guard command || quickHints, commandHeld != command || quickPasteHintsShown != quickHints else { return }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(120))
        modifierHintTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard let self else { return }
            if self.commandHeld != command { self.commandHeld = command }
            if self.quickPasteHintsShown != quickHints { self.quickPasteHintsShown = quickHints }
        }
    }
    func waitForModifierHints() async { await modifierHintTask?.value }
    func quickPasteNumber(at index: Int) -> Int? {
        guard quickPasteHintsShown else { return nil }
        let range = quickPasteRange
        guard range.contains(index), index < visible.count,
              editingClipID == nil, renamingID == nil, !creatingBoard, editingBoardID == nil else { return nil }
        return index - range.lowerBound + 1
    }
    func quickPasteClip(number: Int) -> Clip? {
        let range = quickPasteRange
        let index = range.lowerBound + number - 1
        let clips = visible
        guard (1...9).contains(number), range.contains(index), clips.indices.contains(index),
              editingClipID == nil, renamingID == nil, !creatingBoard, editingBoardID == nil else { return nil }
        return clips[index]
    }
    var selectedID: UUID? { selection.focusedID }
    var selectedClips: [Clip] { visible.filter { selection.ids.contains($0.id) } }
    func resetSelection() {
        if selectionScrollID != nil { selectionScrollID = nil }
        closePreview()
        var next = selection
        next.reset(in: visible.map(\.id))
        if selection != next { selection = next }
    }
    func selectClip(_ clip: Clip, modifiers: NSEvent.ModifierFlags = []) {
        noteImageTextInteraction()
        var next = selection
        next.select(clip.id, in: visible.map(\.id), command: modifiers.contains(.command), shift: modifiers.contains(.shift))
        if next != selection { selection = next }
        if selectionScrollID != nil { selectionScrollID = nil }
    }
    func moveSelection(_ direction: Int, extending: Bool = false) {
        noteImageTextInteraction()
        var next = selection
        next.move(direction, in: visible.map(\.id), extending: extending)
        guard next != selection else { return }
        selection = next
        selectionScrollID = next.focusedID
    }
    func targets(for clip: Clip) -> [Clip] { selection.ids.contains(clip.id) ? selectedClips : [clip] }
    func dragPayload(for clip: Clip) -> String { "clips:" + targets(for: clip).map { $0.id.uuidString }.joined(separator: ",") }
    private var deletions: [History.Deletion] = []
    @Published var renamingID: UUID?
    @Published var renameDraft = ""
    @Published var editingClipID: UUID?
    @Published var editDraft = ""
    @Published var imageDraft: Data?
    @Published var imageOriginal: Data?
    @Published var removingBackground = false
    private var imageEditSession = UUID()
    private var backgroundTask: Task<Void, Never>?
    var pasteTargetName = "当前应用"
    func beginRename(_ clip: Clip) { NSApp.activate(ignoringOtherApps: true); renameDraft = clip.title ?? clip.kind.label; renamingID = clip.id }
    func finishRename() {
        guard let id = renamingID else { return }
        commit { try $0.rename(id: id, title: renameDraft) }
        if !storageFailed { renamingID = nil }
    }
    func beginTextEdit(_ clip: Clip) { cancelTextEdit(); NSApp.activate(ignoringOtherApps: true); editDraft = clip.text; editingClipID = clip.id; previewID = clip.id }
    func beginImageEdit(_ clip: Clip) {
        guard let data = clip.items.flatMap({ $0 }).first(where: { ["public.png", "public.tiff"].contains($0.type) })?.data else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let png = try? ImageEditing.normalizedPNG(data) else { message = "无法读取图片"; return }
        cancelTextEdit()
        imageDraft = png; imageOriginal = png; editingClipID = clip.id; previewID = clip.id
    }
    func rotateImage(clockwise: Bool) {
        guard let data = imageDraft else { return }
        do {
            let rotated = try ImageEditing.rotate(data, clockwise: clockwise)
            if let original = imageOriginal { imageOriginal = try ImageEditing.rotate(original, clockwise: clockwise) }
            imageDraft = rotated
        }
        catch { message = error.localizedDescription }
    }
    @discardableResult
    func removeImageBackground(processor: @escaping @Sendable (Data) throws -> Data = ImageEditing.removeBackground) -> Task<Void, Never>? {
        guard let data = imageDraft, let id = editingClipID, !removingBackground else { return nil }
        removingBackground = true
        let session = imageEditSession
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await Task.detached { Result { try processor(data) } }.value
            guard let self, !Task.isCancelled, self.editingClipID == id, self.imageEditSession == session else { return }
            self.removingBackground = false
            switch result {
            case .success(let png): self.imageDraft = png
            case .failure(let error): self.message = "无法移除背景：\(error.localizedDescription)"
            }
        }
        backgroundTask = task
        return task
    }
    func cancelTextEdit() {
        guard editingClipID != nil || backgroundTask != nil || removingBackground || imageDraft != nil || imageOriginal != nil else { return }
        imageEditSession = UUID()
        backgroundTask?.cancel(); backgroundTask = nil
        removingBackground = false
        editingClipID = nil
        imageDraft = nil; imageOriginal = nil
    }
    func closePreview() { cancelTextEdit(); if previewID != nil { previewID = nil } }
    func finishTextEdit() {
        guard let id = editingClipID, !removingBackground else { return }
        if history.clips.first(where: { $0.id == id })?.kind == .image {
            guard let data = imageDraft else { return }
            commit { try $0.editImage(id: id, png: data) }
        } else { commit { try $0.editText(id: id, text: editDraft) } }
        if !storageFailed { cancelTextEdit() }
    }
    @Published var copiedID: UUID?
    @Published var storageFailed = false
    let preferences: Preferences
    let demo: Bool
    let storageURL: URL
    private let historyWriter: HistoryWriter
    private var storageRevision = 0
    private var captureTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastChange = 0
    private var pendingAt: Date?
    private var locked = false
    private let pasteboard: NSPasteboard
    private let ignoredTypes = ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                                "org.nspasteboard.ConcealedType", "de.petermaurer.TransientPasteboardType"]
    private var nextPrune = Date.distantPast
    var onStackStarted: (() -> Void)?
    var onStackFinished: (() -> Void)?
    @Published var stackPasteAvailable = false
    @Published var stackMode = false
    @Published var stackIDs: [UUID] = []
    var stackClips: [Clip] { stackIDs.compactMap { id in history.clips.first { $0.id == id } } }

    var visible: [Clip] {
        let clips: [Clip]
        if let board = history.boards.first(where: { $0.id == selectedBoardID }) {
            let byID = Dictionary(uniqueKeysWithValues: history.clips.map { ($0.id, $0) })
            clips = board.clipIDs.compactMap { byID[$0] }
        } else { clips = history.clips }
        let searching = hasSearchResults && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return clips.filter {
            (filter == nil || $0.kind == filter) &&
            (selectedSourceIDs.isEmpty || selectedSourceIDs.contains(SourceApplication.id(for: $0))) &&
            (!searching || searchMatches.contains($0.id))
        }
    }
    func clearSearch() {
        if !selectedSourceIDs.isEmpty { selectedSourceIDs = [] }
        if filter != nil { filter = nil }
        replaceSearchText("")
    }
    private func replaceSearchText(_ text: String) {
        if let editor = searchField?.currentEditor() as? NSTextView {
            editor.inputContext?.discardMarkedText()
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        searchField?.stringValue = text
        query = text
    }
    func selectBoard(_ id: UUID?) { selectedBoardID = id; resetSelection() }
    func beginBoardEdit(_ board: Pinboard? = nil, clip: Clip? = nil) {
        namingDroppedBoard = false
        pendingBoardClipIDs = clip.map { targets(for: $0).map(\.id) } ?? []
        searchShown = false
        creatingBoard = board == nil; editingBoardID = board?.id
        boardNameDraft = board?.name ?? L("未命名"); boardColorDraft = board?.color ?? (history.boards.count % 6)
    }
    func dropToNewBoard(_ strings: [String]) -> Bool {
        defer { dropTargetNewBoard = false }
        guard !locked else { return false }
        let known = Set(history.clips.map(\.id))
        var seen = Set<UUID>()
        let ids = strings.flatMap { value -> [UUID] in
            if value.hasPrefix("clips:") {
                return value.dropFirst(6).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            }
            if value.hasPrefix("clip:"), let id = UUID(uuidString: String(value.dropFirst(5))) { return [id] }
            return []
        }.filter { known.contains($0) && seen.insert($0).inserted }
        guard !ids.isEmpty else { return false }
        beginBoardEdit()
        pendingBoardClipIDs = ids
        boardNameDraft = ""
        namingDroppedBoard = true
        return true
    }
    func cancelBoardEdit() { namingDroppedBoard = false; creatingBoard = false; editingBoardID = nil; pendingBoardClipIDs = [] }
    func finishBoardEdit() {
        let name = boardNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingBoardID { commit { try $0.editBoard(id: id, name: name, color: boardColorDraft) } }
        else if creatingBoard {
            var id: UUID?
            commit { history in
                id = try history.addBoard(name: name, color: boardColorDraft)
                if let id { for clipID in pendingBoardClipIDs.reversed() { history.addToBoard(clipID: clipID, boardID: id) } }
            }
            if let id, history.boards.contains(where: { $0.id == id }) { selectBoard(id) }
        }
        if !storageFailed { cancelBoardEdit() }
    }
    func recolorBoard(_ board: Pinboard, color: Int) { commit { try $0.editBoard(id: board.id, name: board.name, color: color) } }
    func removeBoard(_ board: Pinboard) {
        commit { $0.removeBoard(id: board.id) }
        if !storageFailed, selectedBoardID == board.id { selectBoard(nil) }
    }
    func add(_ clip: Clip, to board: Pinboard) {
        let clips = targets(for: clip)
        commit { history in for item in clips.reversed() { history.addToBoard(clipID: item.id, boardID: board.id) } }
    }
    func removeFromCurrentBoard(_ clip: Clip) {
        guard selectedBoardID != nil else { return }
        remove(clip)
    }
    func drop(_ strings: [String], on board: Pinboard) -> Bool {
        defer { dropTargetBoardID = nil }
        guard !locked, history.boards.contains(where: { $0.id == board.id }) else { return false }
        var changed = false
        commit { history in
            for string in strings {
                if string.hasPrefix("clips:") {
                    let ids = string.dropFirst(6).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                    for id in ids.reversed() where history.clips.contains(where: { $0.id == id }) {
                        history.addToBoard(clipID: id, boardID: board.id); changed = true
                    }
                } else if string.hasPrefix("clip:"), let id = UUID(uuidString: String(string.dropFirst(5))), history.clips.contains(where: { $0.id == id }) {
                    history.addToBoard(clipID: id, boardID: board.id); changed = true
                } else if string.hasPrefix("board:"), let id = UUID(uuidString: String(string.dropFirst(6))), history.boards.contains(where: { $0.id == id }) {
                    history.moveBoard(id: id, before: board.id); changed = true
                }
            }
        }
        return changed && !storageFailed
    }

    init(demo: Bool = false, pasteboard: NSPasteboard = .general, storageURL: URL? = nil, preferences: Preferences? = nil, searchIndex: (any ClipboardSearchIndex)? = nil, imageTextService: ImageTextService? = nil) {
        self.searchIndex = searchIndex ?? MemorySearchIndex()
        self.preferences = preferences ?? Preferences()
        self.demo = demo
        self.pasteboard = pasteboard
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipShelf/history.plist")
        historyWriter = HistoryWriter(url: self.storageURL)
        self.imageTextService = imageTextService ?? (demo ? nil : ImageTextService(cacheURL: self.storageURL.appendingPathExtension("ocr.sqlite")))
        if demo { seedDemo(); refreshSourceApps(); scheduleSearch(indexChanged: true); scheduleImageTextRecognition(); return }
        do { history = try History.load(from: self.storageURL) }
        catch { locked = true; storageFailed = true; message = error.localizedDescription }
        if history.clips.contains(where: { $0.kind == .files && singleImageRepresentation(in: $0.items) != nil }) {
            commit { try $0.reclassifyImageFiles() }
        }
        refreshSourceApps()
        scheduleSearch(indexChanged: true)
        scheduleImageTextRecognition()
        // Start with the current counter so opening the app doesn't import an old clipboard.
        lastChange = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func poll() {
        if Date() >= nextPrune { pruneExpired(); nextPrune = Date().addingTimeInterval(60) }
        let change = pasteboard.changeCount
        if paused || locked { lastChange = change; pendingAt = nil; return }
        if change != lastChange { lastChange = change; pendingAt = Date(); return }
        guard let pendingAt, Date().timeIntervalSince(pendingAt) >= 0.3 else { return }
        self.pendingAt = nil
        let previous = captureTask
        captureTask = Task { [weak self] in
            await previous?.value
            await self?.capture(expectedChange: change)
        }
    }

    private struct CapturedContent: Sendable {
        let kind: ClipKind
        let text: String
        let sourceName: String
        let bundle: String
        let items: [[Representation]]
        let identity: Data
        let copiedAt: Date
        func clip() -> Clip {
            Clip(kind: kind, text: text, sourceName: sourceName, sourceBundle: bundle,
                 items: items, identity: identity, copiedAt: copiedAt)
        }
    }
    private func capturedContent(expectedChange: Int, source: NSRunningApplication?) -> CapturedContent? {
        let bundle = source?.bundleIdentifier ?? ""
        guard !preferences.excludes(bundle), let rawItems = pasteboard.pasteboardItems, !rawItems.isEmpty else { return nil }
        guard !rawItems.contains(where: { $0.types.contains(.init("local.clipshelf.credential")) }) else { return nil }
        let allowed: Set<String> = [NSPasteboard.PasteboardType.string.rawValue, "public.utf16-plain-text",
            "public.text", "public.url", "public.file-url", "public.png", "public.tiff", "public.rtf", "public.html"]
        var items: [[Representation]] = []
        for item in rawItems {
            guard !item.types.contains(where: {
                let confidential = $0.rawValue == "org.nspasteboard.ConcealedType"
                return (confidential && preferences.ignoreConfidential) || (!confidential && preferences.ignoreTransient && ignoredTypes.contains($0.rawValue))
            }) else { return nil }
            var representations: [Representation] = []
            for type in item.types where allowed.contains(type.rawValue) {
                guard let data = item.data(forType: type) else { continue }
                representations.append(Representation(type: type.rawValue, data: data))
            }
            if !representations.isEmpty { items.append(representations) }
        }
        guard !items.isEmpty, pasteboard.changeCount == expectedChange else { return nil }
        let flat = items.flatMap { $0 }
        let files = flat.filter { $0.type == "public.file-url" }.compactMap { String(data: $0.data, encoding: .utf8) }
        let kind: ClipKind
        let text: String
        let identity: Data
        if let image = singleImageRepresentation(in: items) {
            kind = .image; text = files.compactMap { URL(string: $0)?.lastPathComponent }.first ?? "图片"; identity = image.data
        } else if !files.isEmpty {
            kind = .files
            text = files.compactMap { URL(string: $0)?.lastPathComponent }.joined(separator: "\n")
            identity = (try? JSONEncoder().encode(files)) ?? Data(files.joined(separator: "\n").utf8)
        } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: trimmed)
            kind = (url?.scheme == "http" || url?.scheme == "https") && !trimmed.contains(where: \.isWhitespace) ? .link : .text
            text = string; identity = Data(string.utf8)
        } else if let url = flat.first(where: { $0.type == "public.url" }), let value = String(data: url.data, encoding: .utf8) {
            kind = .link; text = value; identity = url.data
        } else { return nil }
        guard preferences.captures(kind), pasteboard.changeCount == expectedChange else { return nil }
        return CapturedContent(kind: kind, text: text, sourceName: source?.localizedName ?? "未知应用",
                               bundle: bundle, items: items, identity: identity, copiedAt: Date())
    }
    func capture(expectedChange: Int, source: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) async {
        guard let content = capturedContent(expectedChange: expectedChange, source: source) else { return }
        let clip = await Task.detached(priority: .utility) { content.clip() }.value
        guard !locked, pasteboard.changeCount == expectedChange else { return }
        commitCaptured(clip)
    }
    private func commitCaptured(_ clip: Clip) {
        commit { history in try history.insert(clip) }
        if stackMode, !storageFailed, let id = history.clips.first(where: { $0.fingerprint == clip.fingerprint })?.id, !stackIDs.contains(id) { stackIDs.append(id) }
    }

    private func commit(_ change: (inout History) throws -> Void) {
        guard !locked else { return }
        do {
            var next = history
            try change(&next)
            history = next
            if !demo {
                storageRevision += 1
                let revision = storageRevision
                historyWriter.save(next) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.storageRevision == revision else { return }
                        self.applyStorageResult(result)
                    }
                }
            }
        } catch { storageFailed = true; message = "未能保存历史：\(error.localizedDescription)" }
    }

    private func applyStorageResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            if storageFailed { message = nil }
            storageFailed = false
        case .failure(let error):
            storageFailed = true; message = "未能保存历史：\(error.localizedDescription)"
        }
    }
    @discardableResult func flushStorage() -> Bool {
        applyStorageResult(Result { try historyWriter.flush() })
        return !storageFailed
    }
    func finishPendingStorage() async -> Bool {
        imageTextStopped = true
        imageTextTask?.cancel()
        imageTextService?.cancelRecognition()
        await imageTextTask?.value
        timer?.fireDate = .distantFuture
        defer { timer?.fireDate = Date().addingTimeInterval(0.25) }
        await captureTask?.value
        while true {
            let revision = storageRevision
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                historyWriter.finish { continuation.resume(returning: $0) }
            }
            guard revision == storageRevision else { continue }
            applyStorageResult(result)
            if storageFailed {
                imageTextService?.resumeRecognition()
                imageTextStopped = false; scheduleImageTextRecognition()
            }
            return !storageFailed
        }
    }

    @discardableResult func copy(_ clip: Clip) -> Bool { copy([clip]) }
    @discardableResult func copy(_ clips: [Clip], plainText: Bool = false) -> Bool {
        guard !clips.isEmpty else { return false }
        // Demo only previews controls and never touches the user's clipboard.
        if demo { copiedID = clips.first?.id; return true }
        let objects: [NSPasteboardItem]
        if (plainText && clips.allSatisfy({ $0.kind != .image })) || (clips.count > 1 && clips.allSatisfy({ $0.kind == .text || $0.kind == .link })) {
            let item = NSPasteboardItem()
            item.setString(clips.map(\.text).joined(separator: "\n"), forType: .string)
            objects = [item]
        } else {
            objects = clips.flatMap(\.items).map { representations in
                let item = NSPasteboardItem()
                for representation in representations { item.setData(representation.data, forType: .init(representation.type)) }
                return item
            }
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(objects) else { message = "未能写入剪贴板，请重试。"; return false }
        lastChange = pasteboard.changeCount; pendingAt = nil
        copiedID = clips.first?.id; message = nil
        commit { history in
            for clip in clips.reversed() {
                guard var current = history.clips.first(where: { $0.id == clip.id }) else { continue }
                current.copiedAt = Date()
                try history.insert(current)
                for board in history.boards where board.clipIDs.contains(current.id) {
                    history.removeFromBoard(clipID: current.id, boardID: board.id)
                    history.addToBoard(clipID: current.id, boardID: board.id)
                }
            }
        }
        return true
    }

    func remove(_ clip: Clip) {
        guard !locked else { return }
        let clips = targets(for: clip)
        let boardID = selectedBoardID
        let snapshot = boardID.map { id in History(clips: history.clips, boards: history.boards.filter { $0.id == id }) } ?? history
        let deletion = snapshot.deletion(for: Set(clips.map(\.id)))
        commit { history in
            for item in clips {
                if let boardID { history.removeFromBoard(clipID: item.id, boardID: boardID) }
                else { history.remove(id: item.id) }
            }
        }
        guard !storageFailed else { return }
        deletions.append(deletion)
        while deletions.count > 20 { deletions.removeFirst() }
        resetSelection()
    }
    func undoDeletion() {
        guard !locked, let deletion = deletions.last else { return }
        commit { try $0.restore(deletion) }
        guard !storageFailed else { return }
        deletions.removeLast()
        resetSelection()
    }
    func setRetention(_ retention: RetentionPeriod) {
        if let cutoff = retention.cutoff() { commit { $0.prune(before: cutoff) } }
        if !storageFailed { preferences.retention = retention; resetSelection() }
    }
    func pruneExpired() {
        guard !demo, !locked, let cutoff = preferences.retention.cutoff(),
              history.clips.contains(where: { clip in clip.copiedAt < cutoff && !history.boards.contains(where: { $0.clipIDs.contains(clip.id) }) }) else { return }
        commit { $0.prune(before: cutoff) }
    }
    func advanceBoard(_ direction: Int) {
        let ids: [UUID?] = [nil] + history.boards.map { Optional($0.id) }
        let index = ids.firstIndex(of: selectedBoardID) ?? 0
        selectBoard(ids[(index + direction + ids.count) % ids.count])
    }
    func startStack(includeSelection: Bool = true) {
        let clips = includeSelection ? selectedClips : []
        stackMode = true
        if stackIDs.isEmpty { stackIDs = clips.map(\.id) }
        onStackStarted?()
    }
    func toggleStack(includeSelection: Bool = true) {
        if stackMode { finishStack() }
        else { startStack(includeSelection: includeSelection) }
    }
    func finishStack() {
        guard stackMode else { return }
        stackMode = false
        onStackFinished?()
    }
    @discardableResult func prepareStackPaste() -> Bool {
        guard stackMode else { return false }
        if !demo, pasteboard.changeCount != lastChange || pendingAt != nil {
            // shortcut: an immediate queue paste must capture before overwriting the pasteboard; only this race path hashes synchronously.
            if let content = capturedContent(expectedChange: pasteboard.changeCount, source: NSWorkspace.shared.frontmostApplication) {
                commitCaptured(content.clip())
            }
        }
        guard let clip = stackClips.first,
              copy([clip], plainText: preferences.alwaysPlainText) else { return false }
        stackIDs.removeAll { $0 == clip.id }
        return true
    }
    func clearUnpinned() { commit { $0.removeUnpinned() }; resetSelection() }
    func count(_ kind: ClipKind?) -> Int { history.clips.filter { kind == nil || $0.kind == kind }.count }

    private func seedDemo() {
        let samples: [(ClipKind, String, String)] = [
            (.text, "好的想法，值得留下。\n\n把刚才复制的内容收进来，需要的时候再找回。", "备忘录"),
            (.link, "https://developer.apple.com/design/human-interface-guidelines", "Safari"),
            (.text, "会议记录\n\n✓ 历史记录与内容去重\n✓ 本地搜索\n✓ 卡片式预览\n\n下一步：把灵感变成作品。", "备忘录"),
            (.text, "let ideas = clipboard.history\n    .filter { $0.isWorthKeeping }", "Xcode"),
            (.files, "品牌素材.sketch\n界面参考.png\n项目说明.pdf", "访达"),
            (.text, "Less, but better.\n\n少一点打断，多一点专注。", "Safari")
        ]
        if let iconURL = Bundle.main.url(forResource: "ClipShelf", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL), let tiff = icon.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            let image = Clip(kind: .image, text: "图片", sourceName: "ClipShelf", sourceBundle: "",
                             items: [[Representation(type: "public.png", data: png)]], identity: png,
                             copiedAt: Date().addingTimeInterval(-1800))
            try? history.insert(image)
        }
        for (index, sample) in samples.enumerated().reversed() {
            let data = Data(sample.1.utf8)
            let clip = Clip(kind: sample.0, text: sample.1, sourceName: sample.2, sourceBundle: ["备忘录": "com.apple.Notes", "Safari": "com.apple.Safari", "Xcode": "com.apple.dt.Xcode", "访达": "com.apple.finder"][sample.2] ?? "",
                            items: [[Representation(type: "public.utf8-plain-text", data: data)]], identity: data,
                            copiedAt: Date().addingTimeInterval(Double(-index * 240)))
            try? history.insert(clip)
        }
        if let link = history.clips.first(where: { $0.kind == .link }), let board = history.boards.first { history.addToBoard(clipID: link.id, boardID: board.id) }
    }
}
