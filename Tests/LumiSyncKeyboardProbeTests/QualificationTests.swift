import XCTest
@testable import LumiSyncKeyboardProbe

final class QualificationTests: XCTestCase {
    func testQualificationRequiresExactOSBuildAndSelectorSignatures() {
        let saved = fixture(build: "24G90", setterEncoding: "B@:fQ")

        XCTAssertEqual(
            BacklightQualificationPolicy().evaluate(saved: saved, current: saved),
            .qualified(saved)
        )
        XCTAssertNotEqual(
            BacklightQualificationPolicy().evaluate(
                saved: saved,
                current: fixture(build: "24G91", setterEncoding: "B@:fQ")
            ),
            .qualified(saved)
        )
        XCTAssertNotEqual(
            BacklightQualificationPolicy().evaluate(
                saved: saved,
                current: fixture(build: "24G90", setterEncoding: "v@:fQ")
            ),
            .qualified(saved)
        )
    }

    func testQualificationRejectsIncompleteOrUnsupportedCurrentIdentity() {
        let saved = fixture()
        let invalidIdentities = [
            fixture(modelIdentifier: ""),
            fixture(architecture: "x86_64"),
            fixture(macOSVersion: ""),
            fixture(build: ""),
            fixture(frameworkPresent: false),
            fixture(classPresent: false),
            fixture(selectorName: ""),
            fixture(setterEncoding: "")
        ]

        for current in invalidIdentities {
            guard case .unqualified = BacklightQualificationPolicy().evaluate(
                saved: saved,
                current: current
            ) else {
                return XCTFail("expected unqualified identity: \(current)")
            }
        }
    }

    func testCoreBrightnessInspectionUsesInjectedObjectiveCMetadataProvider() throws {
        let provider = RecordingObjectiveCMetadataProvider(encodings: [
            "copyKeyboardBacklightIDs": "@@:",
            "isKeyboardBuiltIn:": "B@:Q",
            "brightnessForKeyboard:": "f@:Q",
            "setBrightness:forKeyboard:": "B@:fQ"
        ])

        let inspection = try CoreBrightnessKeyboardBacklightBackend.inspectSignatures(
            metadataProvider: provider
        )

        XCTAssertTrue(inspection.frameworkPresent)
        XCTAssertTrue(inspection.classPresent)
        XCTAssertEqual(inspection.selectorSignatures, [
            ObjectiveCSelectorSignature(name: "copyKeyboardBacklightIDs", typeEncoding: "@@:"),
            ObjectiveCSelectorSignature(name: "isKeyboardBuiltIn:", typeEncoding: "B@:Q"),
            ObjectiveCSelectorSignature(name: "brightnessForKeyboard:", typeEncoding: "f@:Q"),
            ObjectiveCSelectorSignature(name: "setBrightness:forKeyboard:", typeEncoding: "B@:fQ")
        ])
        XCTAssertEqual(provider.requestedSelectors, [
            "copyKeyboardBacklightIDs",
            "isKeyboardBuiltIn:",
            "brightnessForKeyboard:",
            "setBrightness:forKeyboard:"
        ])
    }
}

private extension QualificationTests {
    func fixture(
        modelIdentifier: String = "MacBookPro18,3",
        architecture: String = "arm64",
        macOSVersion: String = "15.6.1",
        build: String = "24G90",
        frameworkPresent: Bool = true,
        classPresent: Bool = true,
        selectorName: String = "setBrightness:forKeyboard:",
        setterEncoding: String = "B@:fQ"
    ) -> BacklightQualificationIdentity {
        BacklightQualificationIdentity(
            modelIdentifier: modelIdentifier,
            architecture: architecture,
            macOSVersion: macOSVersion,
            macOSBuild: build,
            frameworkPresent: frameworkPresent,
            classPresent: classPresent,
            selectorSignatures: [
                ObjectiveCSelectorSignature(
                    name: selectorName,
                    typeEncoding: setterEncoding
                )
            ]
        )
    }
}

private final class RecordingObjectiveCMetadataProvider: ObjectiveCMetadataProviding {
    private let encodings: [String: String]
    private(set) var requestedSelectors: [String] = []

    init(encodings: [String: String]) {
        self.encodings = encodings
    }

    func frameworkIsPresent(at path: String) -> Bool {
        true
    }

    func classIsPresent(named name: String) -> Bool {
        true
    }

    func typeEncoding(classNamed name: String, selectorNamed selectorName: String) -> String? {
        requestedSelectors.append(selectorName)
        return encodings[selectorName]
    }
}
