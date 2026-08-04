import LumiSyncCore
import SwiftUI

@main
struct LumiSyncApp: App {
    private let preferences = LumiSyncPreferences.defaults

    var body: some Scene {
        MenuBarExtra("LumiSync", systemImage: "keyboard.badge.ellipsis") {
            VStack(alignment: .leading, spacing: 12) {
                Text("LumiSync")
                    .font(.headline)
                Text("App and Helper boundary scaffold")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
            }
            .padding()
        }

        Settings {
            SettingsView(
                snapshot: SettingsSnapshot(
                    status: "Setup required",
                    selectedSource: "Not connected",
                    fallbackReason: nil,
                    preferences: preferences,
                    inputMonitoringPermission: .notDetermined,
                    helperAuthorization: .notDetermined
                )
            )
        }
    }
}
