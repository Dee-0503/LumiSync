import Foundation
import LumiSyncCore

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var localeIdentifier: String? {
        switch self {
        case .system:
            nil
        case .simplifiedChinese:
            "zh-Hans"
        case .english:
            "en"
        }
    }
}

public struct AppPreferences: Equatable, Codable, Sendable {
    public var core: LumiSyncPreferences
    public var isPaused: Bool
    public var language: AppLanguage

    public init(
        core: LumiSyncPreferences,
        isPaused: Bool,
        language: AppLanguage = .system
    ) {
        self.core = core
        self.isPaused = isPaused
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case core
        case isPaused
        case language
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        core = try container.decode(LumiSyncPreferences.self, forKey: .core)
        isPaused = try container.decode(Bool.self, forKey: .isPaused)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
    }

    public static let defaults = AppPreferences(
        core: .defaults,
        isPaused: false,
        language: .system
    )
}

public protocol AppPreferencesStoring: AnyObject {
    func load() throws -> AppPreferences
    func save(_ preferences: AppPreferences) throws
}

public final class UserDefaultsAppPreferencesStore: AppPreferencesStoring {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String = "LumiSync.AppPreferences") {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> AppPreferences {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }
        return try decoder.decode(AppPreferences.self, from: data)
    }

    public func save(_ preferences: AppPreferences) throws {
        defaults.set(try encoder.encode(preferences), forKey: key)
    }
}
