import Foundation
import Testing
@testable import ClipShelf

struct AppLanguageTests {
    @Test func firstLaunchUsesSystemLanguageOrEnglishFallback() {
        #expect(AppLanguage.initial(preferredLanguages: ["zh-Hans-CN"]) == .chinese)
        #expect(AppLanguage.initial(preferredLanguages: ["zh-Hant-TW"]) == .chinese)
        #expect(AppLanguage.initial(preferredLanguages: ["zh_CN"]) == .chinese)
        #expect(AppLanguage.initial(preferredLanguages: ["en-GB"]) == .english)
        #expect(AppLanguage.initial(preferredLanguages: ["fr-FR", "zh-Hans"]) == .english)
        #expect(AppLanguage.initial(preferredLanguages: []) == .english)
    }
    @Test @MainActor func chosenLanguagePersistsAcrossLaunchesAndSystemChanges() throws {
        let name = "ClipShelf-language-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = Preferences(defaults: defaults, preferredLanguages: ["zh-Hans"])
        #expect(first.language == .chinese)
        #expect(defaults.string(forKey: "appLanguage") == "zh-Hans")
        first.language = .english
        #expect(Preferences(defaults: defaults, preferredLanguages: ["zh-Hans"]).language == .english)
        first.language = .chinese
        #expect(Preferences(defaults: defaults, preferredLanguages: ["en-US"]).language == .chinese)
    }
    @Test func interfaceTranslationsPreserveFormattingAndChinese() {
        #expect(AppLocalization.text("语言", language: .english) == "Language")
        #expect(AppLocalization.text("通用", language: .english) == "General")
        #expect(AppLocalization.text("全部记录", language: .english) == "All History")
        #expect(AppLocalization.text("粘贴到 %@", language: .english) == "Paste into %@")
        #expect(AppLocalization.text("语言", language: .chinese) == "语言")
    }
}
