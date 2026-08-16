import Foundation

public struct AppLocalizer: Sendable {
    public let language: AppLanguage

    public init(language: AppLanguage) {
        self.language = language
    }

    public func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    public func string(_ key: String, arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    public func displaySource(_ source: String) -> String {
        switch source {
        case "Not available":
            string("source.notAvailable")
        case "Built-in display":
            string("source.builtIn")
        case "Main display":
            string("source.main")
        case "Main external display":
            string("source.mainExternal")
        default:
            source
        }
    }

    public func fallbackReason(_ reason: String) -> String {
        switch reason {
        case "No readable display brightness is available through public macOS APIs.":
            string("fallback.noReadableDisplay")
        case "Main display brightness is unavailable; using the built-in display.":
            string("fallback.mainUnavailableUsingBuiltIn")
        default:
            reason
        }
    }

    public var locale: Locale {
        language.localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    static func resourceLanguageIdentifier(for identifier: String) -> String {
        let language = Locale(identifier: identifier).language
        guard language.languageCode?.identifier == "zh" else {
            return "en"
        }
        if language.script?.identifier == "Hans" {
            return "zh-Hans"
        }
        switch language.region?.identifier {
        case "CN", "SG":
            return "zh-Hans"
        default:
            return "en"
        }
    }

    private var bundle: Bundle {
        let resourceIdentifier: String
        switch language {
        case .system:
            resourceIdentifier = Self.resourceLanguageIdentifier(
                for: Locale.preferredLanguages.first ?? "en"
            )
        case .simplifiedChinese:
            resourceIdentifier = "zh-Hans"
        case .english:
            resourceIdentifier = "en"
        }

        let directoryName = resourceIdentifier.lowercased()
        guard let resourceBundle = Self.resourceBundle,
              let path = resourceBundle.path(forResource: directoryName, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return .main
        }
        return localizedBundle
    }

    private static let resourceBundle: Bundle? = {
        let bundleName = "LumiSync_LumiSyncAppSupport.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName)
        ].compactMap { $0 }

        if let explicitBundle = candidates.lazy
            .compactMap({ Bundle(url: $0) })
            .first(where: { $0.path(forResource: "en", ofType: "lproj") != nil }) {
            return explicitBundle
        }

        let developmentBundle = Bundle.module
        return developmentBundle.path(forResource: "en", ofType: "lproj") == nil
            ? nil
            : developmentBundle
    }()
}
