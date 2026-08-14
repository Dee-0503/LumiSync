import Foundation
import LumiSyncCore

public struct AppPreferences: Equatable, Codable, Sendable {
    public var core: LumiSyncPreferences
    public var isPaused: Bool

    public init(core: LumiSyncPreferences, isPaused: Bool) {
        self.core = core
        self.isPaused = isPaused
    }

    public static let defaults = AppPreferences(core: .defaults, isPaused: false)
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
