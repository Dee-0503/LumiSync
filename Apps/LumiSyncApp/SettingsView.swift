import LumiSyncAppSupport
import LumiSyncCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private var localizer: AppLocalizer {
        model.localizer
    }

    var body: some View {
        Form {
            Section(localizer.string("settings.synchronization")) {
                LabeledContent(localizer.string("settings.status"), value: model.statusDescription)
                LabeledContent(localizer.string("settings.selectedSource"), value: model.sourceDescription)

                if let fallbackReason = model.snapshot.fallbackReason {
                    Text(model.localizedFallbackReason(fallbackReason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    localizer.string("settings.pauseSynchronization"),
                    isOn: Binding(
                        get: { model.snapshot.isPaused },
                        set: { _ in model.togglePaused() }
                    )
                )
            }

            Section(localizer.string("settings.configuration")) {
                Picker(
                    localizer.string("settings.language"),
                    selection: Binding(
                        get: { model.snapshot.language },
                        set: { model.setLanguage($0) }
                    )
                ) {
                    Text(localizer.string("language.system"))
                        .tag(AppLanguage.system)
                    Text(localizer.string("language.simplifiedChinese"))
                        .tag(AppLanguage.simplifiedChinese)
                    Text(localizer.string("language.english"))
                        .tag(AppLanguage.english)
                }
                LabeledContent(localizer.string("settings.preset"), value: presetName)
                LabeledContent(localizer.string("settings.intensity"), value: intensityDescription)
                LabeledContent(localizer.string("settings.exclusions"), value: exclusionsDescription)
            }

            Section(localizer.string("settings.inputMonitoring")) {
                LabeledContent(localizer.string("settings.permission"), value: inputMonitoringDescription)
                LabeledContent(localizer.string("settings.sourceListener"), value: keyboardInputListenerDescription)
                Text(localizer.string("settings.inputPrivacy"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(localizer.string("settings.requestAccess")) {
                        model.requestInputMonitoring()
                    }
                    Button(localizer.string("settings.openSystemSettings")) {
                        model.openInputMonitoringSettings()
                    }
                }
            }

            Section(localizer.string("settings.keyboardBacklight")) {
                LabeledContent(localizer.string("settings.capability"), value: keyboardBacklightDescription)
                Text(localizer.string("settings.backlightUnavailableHelp"))
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
                localizer.string("preset.comfort")
            case .alwaysOn:
                localizer.string("preset.alwaysOn")
            case .energySaver:
                localizer.string("preset.energySaver")
            }
        case .custom:
            localizer.string("preset.custom")
        }
    }

    private var intensityDescription: String {
        model.snapshot.preferences.intensity.formatted(
            .percent.precision(.fractionLength(0))
        )
    }

    private var exclusionsDescription: String {
        let count = model.snapshot.preferences.excludedKeyboardDevices.count
        return count == 0
            ? localizer.string("value.none")
            : localizer.string("value.devices", arguments: count)
    }

    private var inputMonitoringDescription: String {
        switch model.snapshot.inputMonitoringStatus {
        case .notDetermined:
            localizer.string("permission.notDetermined")
        case .denied:
            localizer.string("permission.notGranted")
        case .granted:
            localizer.string("permission.granted")
        }
    }

    private var keyboardInputListenerDescription: String {
        guard model.snapshot.inputMonitoringStatus == .granted else {
            return localizer.string("listener.notStarted")
        }
        return model.snapshot.keyboardInputMonitoringActive
            ? localizer.string("status.active")
            : localizer.string("value.unavailable")
    }

    private var keyboardBacklightDescription: String {
        switch model.snapshot.keyboardBacklightStatus {
        case .available:
            localizer.string("value.available")
        case .unavailable:
            localizer.string("value.unavailable")
        }
    }
}
