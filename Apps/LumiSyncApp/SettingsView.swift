import LumiSyncAppSupport
import LumiSyncCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Synchronization") {
                LabeledContent("Status", value: model.statusDescription)
                LabeledContent("Selected source", value: model.sourceDescription)

                if let fallbackReason = model.snapshot.fallbackReason {
                    Text(fallbackReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Pause synchronization",
                    isOn: Binding(
                        get: { model.snapshot.isPaused },
                        set: { _ in model.togglePaused() }
                    )
                )
            }

            Section("Configuration") {
                LabeledContent("Preset", value: presetName)
                LabeledContent("Intensity", value: intensityDescription)
                LabeledContent("Exclusions", value: exclusionsDescription)
            }

            Section("Input Monitoring") {
                LabeledContent("Permission", value: inputMonitoringDescription)
                Text("LumiSync only checks the permission state and provides the request entry point. It does not record key contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Request Access") {
                        model.requestInputMonitoring()
                    }
                    Button("Open System Settings") {
                        model.openInputMonitoringSettings()
                    }
                }
            }

            Section("Keyboard Backlight") {
                LabeledContent("Capability", value: keyboardBacklightDescription)
                Text("No supported public macOS API is connected. LumiSync reports this capability as unavailable and never claims a successful hardware write.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var presetName: String {
        switch model.snapshot.preferences.curveSelection {
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
        model.snapshot.preferences.intensity.formatted(
            .percent.precision(.fractionLength(0))
        )
    }

    private var exclusionsDescription: String {
        let count = model.snapshot.preferences.excludedKeyboardDevices.count
        return count == 0 ? "None" : "\(count) device\(count == 1 ? "" : "s")"
    }

    private var inputMonitoringDescription: String {
        switch model.snapshot.inputMonitoringStatus {
        case .notDetermined:
            "Not determined"
        case .denied:
            "Not granted"
        case .granted:
            "Granted"
        }
    }

    private var keyboardBacklightDescription: String {
        switch model.snapshot.keyboardBacklightStatus {
        case .available:
            "Available"
        case .unavailable:
            "Unavailable"
        }
    }
}
