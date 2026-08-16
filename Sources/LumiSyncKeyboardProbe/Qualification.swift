public struct ObjectiveCSelectorSignature: Codable, Equatable, Sendable {
    public let name: String
    public let typeEncoding: String

    public init(name: String, typeEncoding: String) {
        self.name = name
        self.typeEncoding = typeEncoding
    }
}

public struct BacklightQualificationIdentity: Codable, Equatable, Sendable {
    public let modelIdentifier: String
    public let architecture: String
    public let macOSVersion: String
    public let macOSBuild: String
    public let frameworkPresent: Bool
    public let classPresent: Bool
    public let selectorSignatures: [ObjectiveCSelectorSignature]

    public init(
        modelIdentifier: String,
        architecture: String,
        macOSVersion: String,
        macOSBuild: String,
        frameworkPresent: Bool,
        classPresent: Bool,
        selectorSignatures: [ObjectiveCSelectorSignature]
    ) {
        self.modelIdentifier = modelIdentifier
        self.architecture = architecture
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.frameworkPresent = frameworkPresent
        self.classPresent = classPresent
        self.selectorSignatures = selectorSignatures
    }
}

public enum BacklightQualificationState: Codable, Equatable, Sendable {
    case unqualified(reason: String)
    case qualified(BacklightQualificationIdentity)
}

public struct BacklightQualificationPolicy: Sendable {
    public init() {}

    public func evaluate(
        saved: BacklightQualificationIdentity,
        current: BacklightQualificationIdentity
    ) -> BacklightQualificationState {
        guard let invalidReason = invalidReason(for: current) else {
            guard saved == current else {
                return .unqualified(reason: "Current CoreBrightness identity does not exactly match the saved qualification.")
            }
            return .qualified(current)
        }
        return .unqualified(reason: invalidReason)
    }

    private func invalidReason(for identity: BacklightQualificationIdentity) -> String? {
        guard !identity.modelIdentifier.isEmpty else {
            return "Model identifier is empty."
        }
        guard identity.architecture == "arm64" else {
            return "Architecture is not arm64."
        }
        guard !identity.macOSVersion.isEmpty else {
            return "macOS version is empty."
        }
        guard !identity.macOSBuild.isEmpty else {
            return "macOS build is empty."
        }
        guard identity.frameworkPresent else {
            return "CoreBrightness framework is unavailable."
        }
        guard identity.classPresent else {
            return "KeyboardBrightnessClient class is unavailable."
        }
        guard !identity.selectorSignatures.isEmpty else {
            return "CoreBrightness selector signatures are empty."
        }
        guard identity.selectorSignatures.allSatisfy({
            !$0.name.isEmpty && !$0.typeEncoding.isEmpty
        }) else {
            return "CoreBrightness selector signature is incomplete."
        }
        return nil
    }
}

public struct CoreBrightnessSignatureInspection: Equatable, Sendable {
    public let frameworkPresent: Bool
    public let classPresent: Bool
    public let selectorSignatures: [ObjectiveCSelectorSignature]

    public init(
        frameworkPresent: Bool,
        classPresent: Bool,
        selectorSignatures: [ObjectiveCSelectorSignature]
    ) {
        self.frameworkPresent = frameworkPresent
        self.classPresent = classPresent
        self.selectorSignatures = selectorSignatures
    }
}
