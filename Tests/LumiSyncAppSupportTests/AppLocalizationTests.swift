import XCTest
@testable import LumiSyncAppSupport

final class AppLocalizationTests: XCTestCase {
    func testEnglishAndSimplifiedChineseResolveRepresentativeStrings() {
        let english = AppLocalizer(language: .english)
        let chinese = AppLocalizer(language: .simplifiedChinese)

        XCTAssertEqual(english.string("menu.pause"), "Pause")
        XCTAssertEqual(chinese.string("menu.pause"), "暂停")
        XCTAssertEqual(english.string("settings.language"), "Language")
        XCTAssertEqual(chinese.string("settings.language"), "语言")
    }

    func testLanguageLocaleIdentifiers() {
        XCTAssertNil(AppLanguage.system.localeIdentifier)
        XCTAssertEqual(AppLanguage.simplifiedChinese.localeIdentifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.english.localeIdentifier, "en")
    }

    func testTraditionalChineseSystemLocalesFallBackToEnglish() {
        XCTAssertEqual(AppLocalizer.resourceLanguageIdentifier(for: "zh-Hant"), "en")
        XCTAssertEqual(AppLocalizer.resourceLanguageIdentifier(for: "zh-TW"), "en")
        XCTAssertEqual(AppLocalizer.resourceLanguageIdentifier(for: "zh-HK"), "en")
    }

    func testSimplifiedChineseSystemLocalesUseSimplifiedChinese() {
        XCTAssertEqual(AppLocalizer.resourceLanguageIdentifier(for: "zh-Hans"), "zh-Hans")
        XCTAssertEqual(AppLocalizer.resourceLanguageIdentifier(for: "zh-CN"), "zh-Hans")
        XCTAssertEqual(AppLocalizer.resourceLanguageIdentifier(for: "zh-SG"), "zh-Hans")
    }

    func testDisplayDescriptionsResolveProductionStrings() {
        let chinese = AppLocalizer(language: .simplifiedChinese)

        XCTAssertEqual(chinese.displaySource("Main display"), "主显示器")
        XCTAssertEqual(
            chinese.fallbackReason("Main display brightness is unavailable; using the built-in display."),
            "主显示器亮度不可用；正在使用内置显示器。"
        )
    }

    func testMissingKeyFallsBackToKey() {
        XCTAssertEqual(AppLocalizer(language: .english).string("missing.key"), "missing.key")
    }
}
