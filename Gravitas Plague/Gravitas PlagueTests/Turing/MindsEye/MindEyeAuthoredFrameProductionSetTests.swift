import CryptoKit
import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFrameProductionSetTests: XCTestCase {
    func testPublishedProductionSetIsCompleteAndSemanticallyValid() throws {
        let root = productionRoot()
        let indexData = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let index = try JSONDecoder().decode(MindEyeAuthoredFrameIndex.self, from: indexData)
        XCTAssertTrue(MindEyeAuthoredFrameIndexValidator.validate(index).isEmpty)
        XCTAssertEqual(index.entries.count, 37)

        let exclusions: Set<String> = [
            "chapter02.room.rich.windowRecognition.001",
            "chapter02.room.rich.womanBattle.001",
            "prologue.rich.battle01.mrsDempsey.001",
            "chapter01.room.rich.dadFinalBattle.musicThirtySeconds.001",
            "chapter01.room.rich.dadFinalBattle.oneDamageRemaining.001",
            "chapter03.battle.biker.rich.001",
            "chapter03.battle.mike.recognition.001",
            "chapter03.battle.mike.surrender.002",
        ]
        var aggregatePoses: Set<MindEyeMouthPose> = []
        var decodedIDs: Set<String> = []
        for entry in index.entries {
            let file = root.appendingPathComponent("\(entry.prID).mouthframes.json")
            let data = try Data(contentsOf: file)
            XCTAssertEqual(Self.sha256(data), entry.manifestSHA256)
            let manifest = try JSONDecoder().decode(MindEyeAuthoredFrameManifest.self, from: data)
            XCTAssertTrue(MindEyeAuthoredFrameManifestValidator.validate(manifest).isEmpty)
            XCTAssertEqual(manifest.prID, entry.prID)
            XCTAssertEqual(manifest.speakerCharacterID, entry.speakerCharacterID)
            XCTAssertEqual(manifest.interactionSurface, entry.interactionSurface)
            XCTAssertEqual(manifest.timeline.sampleCount, entry.sampleCount)
            XCTAssertEqual(manifest.timeline.frameCount, entry.frameCount)
            XCTAssertEqual(manifest.summary.poseFrameCounts["rest"], entry.poseFrameCounts.rest)
            XCTAssertEqual(manifest.summary.poseFrameCounts["small"], entry.poseFrameCounts.small)
            XCTAssertEqual(manifest.summary.poseFrameCounts["wide"], entry.poseFrameCounts.wide)
            XCTAssertEqual(manifest.summary.poseFrameCounts["round"], entry.poseFrameCounts.round)
            XCTAssertEqual(manifest.summary.poseFrameCounts["teeth"], entry.poseFrameCounts.teeth)
            XCTAssertEqual(manifest.mouthLayerBits["teeth"], 16)
            for frame in manifest.frames {
                let expected = [
                    MindEyeMouthPose.rest: 1,
                    .small: 2,
                    .wide: 4,
                    .round: 8,
                    .teeth: 16,
                ][frame.pose]
                XCTAssertEqual(frame.layerMask, expected)
                aggregatePoses.insert(frame.pose)
            }
            decodedIDs.insert(manifest.prID)
        }
        XCTAssertEqual(decodedIDs.count, 37)
        XCTAssertTrue(decodedIDs.isDisjoint(with: exclusions))
        XCTAssertEqual(aggregatePoses, Set(MindEyeMouthPose.allCases))
        XCTAssertTrue(decodedIDs.contains("prologue.walkie.bigMike.scriptPoint05.001"))
        XCTAssertTrue(decodedIDs.contains("prologue.walkie.bigMike.scriptPoint05.002"))
    }

    private func productionRoot() -> URL {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TuringResources/Turing/MindsEye/AudioFrames")
        return sourceRoot
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
