import LumiSyncCore
import SwiftUI

struct SettingsSnapshot: Sendable {
    enum PermissionState: String, Sendable {
        case granted = "Granted"
        case denied = "Denied"
        case notDetermined = "Not determined"
    }

    let status: String
    let selectedSource: String
    let fallbackReason: String?
    let preferences: LumiSyncPreferences
    let inputMonitoringPermission: PermissionState
    let helperAuthorization: PermissionState
}

struct SettingsView: View {
    let snapshot: SettingsSnapshot

    var body: some View {
        Form {
            Section("Synchronization") {
                LabeledContent("Status", value: snapshot.status)
                LabeledContent("Selected source", value: snapshot.selectedSource)

                if let fallbackReason = snapshot.fallbackReason {
                    LabeledContent("Fallback reason", value: fallbackReason)
                }
            }

            Section("Configuration") {
                LabeledContent("Preset", value: presetName)
                LabeledContent("Intensity", value: intensityDescription)
                LabeledContent("Exclusions", value: exclusionsDescription)
            }

            Section("Permissions") {
                LabeledContent(
                    "Input Monitoring permission",
                    value: snapshot.inputMonitoringPermission.rawValue
                )
                LabeledContent(
                    "Helper authorization",
                    value: snapshot.helperAuthorization.rawValue
                )
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 360)
    }

    private var presetName: String {
        switch snapshot.preferences.curveSelection {
        case let .preset(preset):
            switch preset {
            case .comfort:
                "Comfort"
            case .alwaysOn:
                "Always On"
            case .energySaver:
                "Energy Saver"
            }
        case .custom:
            "Custom"
        }
    }

    private var intensityDescription: String {
        snapshot.preferences.intensity.formatted(
            .percent.precision(.fractionLength(0))
        )
    }

    private var exclusionsDescription: String {
        let count = snapshot.preferences.excludedKeyboardDevices.count
        return count == 0 ? "None" : "\(count) device\(count == 1 ? "" : "s")"
    }
}
