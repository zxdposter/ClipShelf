import Foundation
import Combine
import AppKit
import Carbon
import ClipboardCore

enum RetentionPeriod: Int, CaseIterable, Identifiable {
    case day, week, month, year, forever
    var id: Self { self }
    var title: String { switch self { case .day: L("天"); case .week: L("周"); case .month: L("个月"); case .year: L("年"); case .forever: L("永久") } }
    func cutoff(now: Date = Date()) -> Date? {
        switch self {
        case .day: Calendar.current.date(byAdding: .day, value: -1, to: now)
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: now)
        case .month: Calendar.current.date(byAdding: .month, value: -1, to: now)
        case .year: Calendar.current.date(byAdding: .year, value: -1, to: now)
        case .forever: nil
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self { case .system: L("跟随系统"); case .light: L("浅色"); case .dark: L("深色") }
    }
    var next: Self { switch self { case .system: .light; case .light: .dark; case .dark: .system } }
    var symbol: String { switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" } }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum PasteDestination: String, CaseIterable { case activeApplication, clipboard }

// Registration is handled by AppDelegate so a failed change keeps the old shortcut.
enum ShelfShortcut: String, CaseIterable, Identifiable {
    case shiftCommandV, optionCommandV, controlOptionV
    var id: Self { self }
    var title: String {
        switch self { case .shiftCommandV: "⇧⌘V"; case .optionCommandV: "⌥⌘V"; case .controlOptionV: "⌃⌥V" }
    }
    var modifiers: UInt32 {
        switch self {
        case .shiftCommandV: UInt32(cmdKey | shiftKey)
        case .optionCommandV: UInt32(cmdKey | optionKey)
        case .controlOptionV: UInt32(controlKey | optionKey)
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appAppearance") }
    }
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "appLanguage")
            if defaults === UserDefaults.standard { AppLocalization.shared.language = language }
        }
    }
    @Published var textEnabled: Bool { didSet { defaults.set(textEnabled, forKey: "capture.text") } }
    @Published var linkEnabled: Bool { didSet { defaults.set(linkEnabled, forKey: "capture.link") } }
    @Published var imageEnabled: Bool { didSet { defaults.set(imageEnabled, forKey: "capture.image") } }
    @Published var filesEnabled: Bool { didSet { defaults.set(filesEnabled, forKey: "capture.files") } }
    @Published var excludedApps: String { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    @Published var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    @Published var shortcut: ShelfShortcut { didSet { defaults.set(shortcut.rawValue, forKey: "shortcut") } }

    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var pasteDestination: PasteDestination { didSet { defaults.set(pasteDestination.rawValue, forKey: "pasteDestination") } }
    @Published var alwaysPlainText: Bool { didSet { defaults.set(alwaysPlainText, forKey: "alwaysPlainText") } }
    @Published var retention: RetentionPeriod { didSet { defaults.set(retention.rawValue, forKey: "retention") } }
    @Published var showInScreenSharing: Bool { didSet { defaults.set(showInScreenSharing, forKey: "showInScreenSharing") } }
    @Published var linkPreviews: Bool { didSet { defaults.set(linkPreviews, forKey: "linkPreviews") } }
    @Published var ignoreConfidential: Bool { didSet { defaults.set(ignoreConfidential, forKey: "ignoreConfidential") } }
    @Published var ignoreTransient: Bool { didSet { defaults.set(ignoreTransient, forKey: "ignoreTransient") } }
    @Published var mcpEnabled: Bool { didSet { defaults.set(mcpEnabled, forKey: "mcpEnabled"); defaults.set(UUID().uuidString, forKey: "mcpSessionEpoch"); defaults.synchronize() } }
    @Published private(set) var mcpClients: [String: String]
    func addMCPClient(name: String, token: String) {
        mcpClients[MCPService.credentialID(token)] = name
        defaults.set(mcpClients, forKey: "mcpClients"); defaults.synchronize()
    }
    func revokeMCPClient(_ id: String) {
        mcpClients.removeValue(forKey: id)
        defaults.set(mcpClients, forKey: "mcpClients"); defaults.synchronize()
    }
    @Published var quickPasteModifier: KeyModifier { didSet { defaults.set(quickPasteModifier.rawValue, forKey: "quickPasteModifier") } }
    @Published var quickPasteFromVisibleCards: Bool { didSet { defaults.set(quickPasteFromVisibleCards, forKey: "quickPasteFromVisibleCards") } }
    @Published var plainTextModifier: KeyModifier { didSet { defaults.set(plainTextModifier.rawValue, forKey: "plainTextModifier") } }
    @Published private(set) var bindings: [String: KeyBinding]
    @Published private(set) var disabledBindings: [String]

    func binding(for action: ShortcutAction) -> KeyBinding? {
        if disabledBindings.contains(action.rawValue) { return nil }
        if let value = bindings[action.rawValue] { return value }
        if action == .activate { return KeyBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: shortcut.modifiers, key: "V") }
        return action.defaultBinding
    }
    func setBinding(_ binding: KeyBinding?, for action: ShortcutAction) {
        bindings[action.rawValue] = binding
        disabledBindings.removeAll { $0 == action.rawValue }
        if binding == nil { disabledBindings.append(action.rawValue) }
        defaults.set(try? JSONEncoder().encode(bindings), forKey: "keyBindings")
        defaults.set(disabledBindings, forKey: "disabledBindings")
    }
    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appAppearance") ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "")
            ?? AppLanguage.initial(preferredLanguages: preferredLanguages)
        textEnabled = defaults.object(forKey: "capture.text") as? Bool ?? true
        linkEnabled = defaults.object(forKey: "capture.link") as? Bool ?? true
        imageEnabled = defaults.object(forKey: "capture.image") as? Bool ?? true
        filesEnabled = defaults.object(forKey: "capture.files") as? Bool ?? true
        excludedApps = defaults.string(forKey: "excludedApps") ?? "com.apple.Passwords\ncom.apple.keychainaccess"
        let limit = defaults.integer(forKey: "historyLimit")
        historyLimit = [50, 100, 200].contains(limit) ? limit : 200
        shortcut = ShelfShortcut(rawValue: defaults.string(forKey: "shortcut") ?? "") ?? .shiftCommandV
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        pasteDestination = PasteDestination(rawValue: defaults.string(forKey: "pasteDestination") ?? "") ?? .activeApplication
        alwaysPlainText = defaults.bool(forKey: "alwaysPlainText")
        retention = RetentionPeriod(rawValue: defaults.object(forKey: "retention") as? Int ?? 2) ?? .month
        showInScreenSharing = defaults.object(forKey: "showInScreenSharing") as? Bool ?? true
        // Preview fetching is opt-in because a copied URL can contain sensitive or one-time data.
        linkPreviews = defaults.bool(forKey: "linkPreviews")
        ignoreConfidential = defaults.object(forKey: "ignoreConfidential") as? Bool ?? true
        ignoreTransient = defaults.object(forKey: "ignoreTransient") as? Bool ?? true
        mcpEnabled = defaults.bool(forKey: "mcpEnabled")
        mcpClients = defaults.dictionary(forKey: "mcpClients") as? [String: String] ?? [:]
        quickPasteModifier = KeyModifier(rawValue: defaults.string(forKey: "quickPasteModifier") ?? "") ?? .command
        quickPasteFromVisibleCards = defaults.object(forKey: "quickPasteFromVisibleCards") as? Bool ?? true
        plainTextModifier = KeyModifier(rawValue: defaults.string(forKey: "plainTextModifier") ?? "") ?? .shift
        bindings = defaults.data(forKey: "keyBindings").flatMap { try? JSONDecoder().decode([String: KeyBinding].self, from: $0) } ?? [:]
        disabledBindings = defaults.stringArray(forKey: "disabledBindings") ?? []
        defaults.set(language.rawValue, forKey: "appLanguage")

    }
    func captures(_ kind: ClipKind) -> Bool {
        switch kind { case .text: textEnabled; case .link: linkEnabled; case .image: imageEnabled; case .files: filesEnabled }
    }
    func excludes(_ bundle: String) -> Bool {
        !bundle.isEmpty && excludedApps.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.contains(bundle)
    }
}
