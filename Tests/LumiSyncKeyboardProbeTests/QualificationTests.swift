import XCTest
@testable import LumiSyncKeyboardProbe

final class QualificationTests: XCTestCase {
    func testQualificationRequiresExactOSBuildAndSelectorSignatures() {
        let saved = fixture(build: "24G90")

        XCTAssertEqual(
            BacklightQualificationPolicy().evaluate(saved: saved, current: saved),
            .qualified(saved)
        )
        XCTAssertNotEqual(
            BacklightQualificationPolicy().evaluate(
                saved: saved,
                current: fixture(build: "24G91")
            ),
            .qualified(saved)
        )
        XCTAssertNotEqual(
            BacklightQualificationPolicy().evaluate(
                saved: saved,
                current: fixture(setterEncoding: "v@:fQ")
            ),
            .qualified(saved)
        )
    }

    func testQualificationRejectsIncompleteSavedIdentityBeforeComparingCurrent() {
        let saved = fixture(selectorSignatures: [])

        XCTAssertEqual(
            BacklightQualificationPolicy().evaluate(saved: saved, current: fixture()),
            .unqualified(reason: "Saved CoreBrightness identity is incomplete.")
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
            fixture(selectorSignatures: [])
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

    func testQualificationRejectsMissingRequiredSelectorOrUnsupportedABI() {
        let saved = fixture()
        let required = saved.selectorSignatures
        let missingSelector = fixture(selectorSignatures: Array(required.dropLast()))
        let wrongABI = fixture(
            selectorSignatures: Array(required.dropLast()) + [
                ObjectiveCSelectorSignature(
                    name: "setBrightness:forKeyboard:",
                    typeEncoding: "v@:fQ"
                )
            ]
        )
        let unexpectedSelector = fixture(
            selectorSignatures: required + [
                ObjectiveCSelectorSignature(name: "unexpected:", typeEncoding: "v@:@")
            ]
        )

        for current in [missingSelector, wrongABI, unexpectedSelector] {
            XCTAssertEqual(
                BacklightQualificationPolicy().evaluate(saved: saved, current: current),
                .unqualified(reason: "Current CoreBrightness selector set or ABI is unsupported.")
            )
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
        XCTAssertEqual(provider.events, [
            "load",
            "class:KeyboardBrightnessClient",
            "encoding:copyKeyboardBacklightIDs",
            "encoding:isKeyboardBuiltIn:",
            "encoding:brightnessForKeyboard:",
            "encoding:setBrightness:forKeyboard:"
        ])
    }

    func testQualificationAcceptsRuntimeOffsetsAfterCanonicalizingABI() {
        let runtime = fixture(selectorSignatures: [
            ObjectiveCSelectorSignature(name: "copyKeyboardBacklightIDs", typeEncoding: "@16@0:8"),
            ObjectiveCSelectorSignature(name: "isKeyboardBuiltIn:", typeEncoding: "B24@0:8Q16"),
            ObjectiveCSelectorSignature(name: "brightnessForKeyboard:", typeEncoding: "f24@0:8Q16"),
            ObjectiveCSelectorSignature(name: "setBrightness:forKeyboard:", typeEncoding: "B28@0:8f16Q20")
        ])

        XCTAssertEqual(
            BacklightQualificationPolicy().evaluate(saved: runtime, current: runtime),
            .qualified(runtime)
        )
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
        setterEncoding: String = "B@:fQ",
        selectorSignatures: [ObjectiveCSelectorSignature]? = nil
    ) -> BacklightQualificationIdentity {
        BacklightQualificationIdentity(
            modelIdentifier: modelIdentifier,
            architecture: architecture,
            macOSVersion: macOSVersion,
            macOSBuild: build,
            frameworkPresent: frameworkPresent,
            classPresent: classPresent,
            selectorSignatures: selectorSignatures ?? [
                ObjectiveCSelectorSignature(name: "copyKeyboardBacklightIDs", typeEncoding: "@@:"),
                ObjectiveCSelectorSignature(name: "isKeyboardBuiltIn:", typeEncoding: "B@:Q"),
                ObjectiveCSelectorSignature(name: "brightnessForKeyboard:", typeEncoding: "f@:Q"),
                ObjectiveCSelectorSignature(name: "setBrightness:forKeyboard:", typeEncoding: setterEncoding)
            ]
        )
    }
}

private final class RecordingObjectiveCMetadataProvider: ObjectiveCMetadataProviding {
    private let encodings: [String: String]
    private(set) var events: [String] = []

    init(encodings: [String: String]) {
        self.encodings = encodings
    }

    func loadFramework(at path: String) -> Bool {
        events.append("load")
        return true
    }

    func classIsPresent(named name: String) -> Bool {
        events.append("class:\(name)")
        return true
    }

    func typeEncoding(classNamed name: String, selectorNamed selectorName: String) -> String? {
        events.append("encoding:\(selectorName)")
        return encodings[selectorName]
    }
}
