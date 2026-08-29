import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeVignetteManifestTests: XCTestCase {
    func testShippedCatEye81ManifestDecodesAndValidates() throws {
        let url = mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/TuringResources/Turing/MindsEye/Vignettes/cateye81_bunker/manifest.json"
        )
        let manifest = try JSONDecoder().decode(
            MindEyeVignetteManifest.self,
            from: Data(contentsOf: url)
        )
        let issues = MindEyeVignetteManifestValidator.issues(
            manifest: manifest,
            expectedVignetteID: "cateye81_bunker",
            expectedCharacterID: .catEye81
        )

        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(manifest.layers.mouths.rest.count, 2)
        XCTAssertEqual(manifest.layers.mouths.small, ["mouth-small-01.png"])
        XCTAssertEqual(manifest.layers.mouths.teeth, ["mouth-teeth-01.png"])
    }

    func testShippedAdditionalCharacterManifestsDecodeAndValidate() throws {
        let fixtures: [(
            path: String,
            vignetteID: String,
            characterID: TuringConversationCharacterID,
            expectedWideCount: Int,
            expectedTeethCount: Int
        )] = [
            (
                "rich_current_room",
                "rich_current_room",
                .rich,
                2,
                2
            ),
            (
                "dad_workshop",
                "dad_workshop",
                .dad,
                3,
                1
            ),
            (
                "broadcaster_radio_room",
                "broadcaster_radio_room",
                .broadcaster,
                2,
                1
            )
        ]

        for fixture in fixtures {
            let url = mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/TuringResources/Turing/MindsEye/" +
                    "Vignettes/\(fixture.path)/manifest.json"
            )
            let manifest = try JSONDecoder().decode(
                MindEyeVignetteManifest.self,
                from: Data(contentsOf: url)
            )
            let issues = MindEyeVignetteManifestValidator.issues(
                manifest: manifest,
                expectedVignetteID: fixture.vignetteID,
                expectedCharacterID: fixture.characterID
            )

            XCTAssertTrue(issues.isEmpty, "\(fixture.vignetteID): \(issues)")
            XCTAssertEqual(
                manifest.layers.mouths.wide.count,
                fixture.expectedWideCount
            )
            XCTAssertEqual(
                manifest.layers.mouths.teeth.count,
                fixture.expectedTeethCount
            )
        }
    }

    func testEveryShippedVignetteUsesTheSingleSharedFeatherMask() throws {
        let vignetteIDs = [
            "big_mike_current_room",
            "cateye81_bunker",
            "rich_current_room",
            "dad_workshop",
            "broadcaster_radio_room"
        ]
        let expectedMask = "Turing/MindsEye/Shared/feather-mask.png"

        for vignetteID in vignetteIDs {
            let url = mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/TuringResources/Turing/MindsEye/" +
                    "Vignettes/\(vignetteID)/manifest.json"
            )
            let manifest = try JSONDecoder().decode(
                MindEyeVignetteManifest.self,
                from: Data(contentsOf: url)
            )

            XCTAssertEqual(
                manifest.layers.featherMask,
                expectedMask,
                "\(vignetteID) must use the shared feather mask."
            )
        }
    }

    func testEveryShippedVignetteUsesTheEnlargedCardSize() throws {
        let vignetteIDs = [
            "big_mike_current_room",
            "cateye81_bunker",
            "rich_current_room",
            "dad_workshop",
            "broadcaster_radio_room"
        ]

        for vignetteID in vignetteIDs {
            let url = mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/TuringResources/Turing/MindsEye/" +
                    "Vignettes/\(vignetteID)/manifest.json"
            )
            let manifest = try JSONDecoder().decode(
                MindEyeVignetteManifest.self,
                from: Data(contentsOf: url)
            )
            let placement = try XCTUnwrap(manifest.placement)

            XCTAssertEqual(placement.cardWidthMeters, 0.84, accuracy: 0.0001)
            XCTAssertEqual(placement.cardHeightMeters, 0.4725, accuracy: 0.0001)
        }
    }

    func testProductionShapeValidatesAndTeethIsRequired() {
        XCTAssertTrue(issues(for: makeMindEyeTestManifest()).isEmpty)

        let manifest = makeMindEyeTestManifest(
            mouths: .init(
                rest: ["mouth-rest-01.png"],
                small: ["mouth-small-01.png"],
                wide: ["mouth-wide-01.png"],
                round: ["mouth-round-01.png"],
                teeth: []
            )
        )
        XCTAssertTrue(issues(for: manifest).contains { $0.code == .missingMouthTeeth })
    }

    func testMissingRestAndClosedEyesHaveSpecificCodes() {
        let manifest = makeMindEyeTestManifest(
            eyes: .init(open: ["eyes-open-01.png"], closed: []),
            mouths: .init(
                rest: [],
                small: ["mouth-small-01.png"],
                wide: ["mouth-wide-01.png"],
                round: ["mouth-round-01.png"],
                teeth: ["mouth-teeth-01.png"]
            )
        )
        let codes = Set(issues(for: manifest).map(\.code))
        XCTAssertTrue(codes.contains(.missingEyeClosed))
        XCTAssertTrue(codes.contains(.missingMouthRest))
    }

    func testDuplicateWithinAndAcrossPoseFamiliesIsRejected() {
        let duplicateTeeth = makeMindEyeTestManifest(
            mouths: .init(
                rest: ["mouth-rest-01.png"],
                small: ["mouth-small-01.png"],
                wide: ["mouth-wide-01.png"],
                round: ["mouth-round-01.png"],
                teeth: ["mouth-teeth-01.png", "mouth-teeth-01.png"]
            )
        )
        XCTAssertTrue(issues(for: duplicateTeeth).contains { $0.code == .duplicateAssetReference })

        let reused = makeMindEyeTestManifest(
            mouths: .init(
                rest: ["mouth-rest-01.png"],
                small: ["mouth-small-01.png"],
                wide: ["mouth-teeth-01.png"],
                round: ["mouth-round-01.png"],
                teeth: ["mouth-teeth-01.png"]
            )
        )
        XCTAssertTrue(issues(for: reused).contains { $0.code == .duplicateAssetReference })
    }

    func testCropMotionAndBlinkBoundsAreStrict() {
        var manifest = makeMindEyeTestManifest()
        manifest = MindEyeVignetteManifest(
            schemaVersion: manifest.schemaVersion,
            vignetteID: manifest.vignetteID,
            characterID: manifest.characterID,
            sourceSize: manifest.sourceSize,
            viewportSize: manifest.viewportSize,
            viewportRect: MindEyePixelRect(origin: .init(x: 0, y: 0), size: .viewport),
            layers: manifest.layers,
            depth: manifest.depth,
            motion: MindEyeMotionTuning(
                sharedDriftMaxPixels: manifest.motion.sharedDriftMaxPixels,
                sharedRollMaxDegrees: manifest.motion.sharedRollMaxDegrees,
                sharedScaleMax: manifest.motion.sharedScaleMax,
                characterParallaxMaxPixels: manifest.motion.characterParallaxMaxPixels,
                backgroundCounterMotion: 0.19,
                gripCorrectionMaxPixels: manifest.motion.gripCorrectionMaxPixels,
                gripCorrectionMaxDegrees: manifest.motion.gripCorrectionMaxDegrees
            ),
            blink: MindEyeBlinkTuning(
                ordinaryIntervalMinSeconds: 0.49,
                ordinaryIntervalMaxSeconds: 5.01,
                closedFrameMin: 5,
                closedFrameMax: 8,
                doubleBlinkProbability: 0.08,
                doubleBlinkGapMinSeconds: 0.5,
                doubleBlinkGapMaxSeconds: 1.0
            ),
            placement: manifest.placement
        )
        let codes = Set(issues(for: manifest).map(\.code))
        XCTAssertTrue(codes.contains(.wrongViewportRect))
        XCTAssertTrue(codes.contains(.invalidMotion))
        XCTAssertTrue(codes.contains(.invalidBlink))
    }

    func testManifestWithoutTeethKeyDoesNotDecode() throws {
        let url = mindEyeProjectRoot()
            .appendingPathComponent("Gravitas Plague/TuringResources/Turing/MindsEye/Vignettes/big_mike_current_room/manifest.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var layers = try XCTUnwrap(object["layers"] as? [String: Any])
        var mouths = try XCTUnwrap(layers["mouths"] as? [String: Any])
        mouths.removeValue(forKey: "teeth")
        layers["mouths"] = mouths
        object["layers"] = layers
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MindEyeVignetteManifest.self, from: data))
    }

    private func issues(
        for manifest: MindEyeVignetteManifest
    ) -> [MindEyeManifestValidationIssue] {
        MindEyeVignetteManifestValidator.issues(
            manifest: manifest,
            expectedVignetteID: "big_mike_current_room",
            expectedCharacterID: .bigMike
        )
    }
}

func makeMindEyeTestManifest(
    eyes: MindEyeVignetteManifest.Layers.Eyes = .init(
        open: ["eyes-open-01.png"],
        closed: ["eyes-closed-01.png"]
    ),
    mouths: MindEyeVignetteManifest.Layers.Mouths = .init(
        rest: ["mouth-rest-01.png"],
        small: ["mouth-small-01.png"],
        wide: ["mouth-wide-01.png"],
        round: ["mouth-round-01.png"],
        teeth: ["mouth-teeth-01.png"]
    ),
    characterID: TuringConversationCharacterID = .bigMike,
    vignetteID: String = "big_mike_current_room"
) -> MindEyeVignetteManifest {
    MindEyeVignetteManifest(
        schemaVersion: 1,
        vignetteID: vignetteID,
        characterID: characterID,
        sourceSize: .source,
        viewportSize: .viewport,
        viewportRect: .centeredViewport,
        layers: .init(
            background: "background.png",
            characterBase: "character-base.png",
            featherMask: "feather-mask.png",
            eyes: eyes,
            mouths: mouths
        ),
        depth: .init(cameraToCharacterMeters: 0.75, cameraToBackgroundMeters: 3),
        motion: .init(
            sharedDriftMaxPixels: .init(x: 36, y: 20),
            sharedRollMaxDegrees: 0.55,
            sharedScaleMax: 1.018,
            characterParallaxMaxPixels: .init(x: 18, y: 10),
            backgroundCounterMotion: 0.28,
            gripCorrectionMaxPixels: .init(x: 24, y: 14),
            gripCorrectionMaxDegrees: 0.25
        ),
        blink: .init(
            ordinaryIntervalMinSeconds: 2,
            ordinaryIntervalMaxSeconds: 5,
            closedFrameMin: 5,
            closedFrameMax: 8,
            doubleBlinkProbability: 0.08,
            doubleBlinkGapMinSeconds: 0.5,
            doubleBlinkGapMaxSeconds: 1
        ),
        placement: .init(
            cardWidthMeters: 0.84,
            cardHeightMeters: 0.4725,
            verticalLiftMeters: 0.10,
            forwardOffsetMeters: 0.0381,
            shelfClearanceMeters: 0.0127
        )
    )
}

func mindEyeProjectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
