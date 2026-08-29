import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFrameIndexTests: XCTestCase {
    func testCanonicalIndexRoundTripsAndValidates() throws {
        let value = makeIndex()
        let decoded = try JSONDecoder().decode(
            MindEyeAuthoredFrameIndex.self,
            from: JSONEncoder().encode(value)
        )

        XCTAssertEqual(decoded.entries.count, 37)
        XCTAssertTrue(MindEyeAuthoredFrameIndexValidator.validate(decoded).isEmpty)
    }

    func testUnsortedEntriesAreRejected() {
        let valid = makeIndex()
        let invalid = MindEyeAuthoredFrameIndex(
            schemaVersion: valid.schemaVersion,
            setVersion: valid.setVersion,
            compilerVersion: valid.compilerVersion,
            expectedManifestCount: valid.expectedManifestCount,
            manifestSetSHA256: valid.manifestSetSHA256,
            registrySHA256: valid.registrySHA256,
            toolchainLockSHA256: valid.toolchainLockSHA256,
            compilerConfigSHA256: valid.compilerConfigSHA256,
            phonemePoseMapSHA256: valid.phonemePoseMapSHA256,
            pronunciationOverridesSHA256: valid.pronunciationOverridesSHA256,
            entries: Array(valid.entries.reversed()),
            summary: valid.summary
        )

        XCTAssertTrue(
            MindEyeAuthoredFrameIndexValidator.validate(invalid)
                .contains { $0.code == .authoredFrameIndexInvalid }
        )
    }

    private func makeIndex() -> MindEyeAuthoredFrameIndex {
        let speakers: [TuringConversationCharacterID] =
            Array(repeating: .bigMike, count: 10) +
            Array(repeating: .rich, count: 15) +
            Array(repeating: .broadcaster, count: 5) +
            Array(repeating: .catEye81, count: 5) +
            Array(repeating: .dad, count: 2)
        let surfaces: [StoryInteractionSurfaceID] = [
            .walkie, .dadFrame, .crankRadio, .hamReceiver,
        ]
        let poses = MindEyeAuthoredFrameIndex.Entry.PoseFrameCounts(
            rest: 1,
            small: 1,
            wide: 1,
            round: 1,
            teeth: 1
        )
        let entries = speakers.enumerated().map { index, speaker in
            let prID = String(format: "fixture.%03d", index)
            return MindEyeAuthoredFrameIndex.Entry(
                prID: prID,
                speakerCharacterID: speaker,
                interactionSurface: surfaces[index % surfaces.count],
                manifestResourcePath: "Turing/MindsEye/AudioFrames/\(prID).mouthframes.json",
                manifestSHA256: String(format: "%064llx", index + 1),
                descriptorSHA256: String(repeating: "1", count: 64),
                audioSHA256: String(repeating: "2", count: 64),
                transcriptSHA256: String(repeating: "3", count: 64),
                sampleCount: 4_000,
                frameCount: 5,
                durationSeconds: Double(4_000) / 48_000,
                poseFrameCounts: poses,
                speechFrameCount: 4,
                fallbackFrameCount: 0,
                manualOverrideFrameCount: 0,
                warningCount: 0
            )
        }
        var surfaceCounts: [String: Int] = [:]
        for entry in entries {
            surfaceCounts[entry.interactionSurface.rawValue, default: 0] += 1
        }
        let summary = MindEyeAuthoredFrameIndex.Summary(
            manifestCount: 37,
            speakerManifestCounts: [
                "big_mike": 10, "rich": 15, "broadcaster": 5,
                "cateye81": 5, "dad": 2,
            ],
            surfaceManifestCounts: surfaceCounts,
            totalSampleCount: 148_000,
            totalFrameCount: 185,
            totalDurationSeconds: Double(148_000) / 48_000,
            aggregatePoseFrameCounts: .init(
                rest: 37, small: 37, wide: 37, round: 37, teeth: 37
            ),
            totalSpeechFrameCount: 148,
            totalFallbackFrameCount: 0,
            totalManualOverrideFrameCount: 0,
            totalWarningCount: 0,
            manifestBytes: 1
        )
        return MindEyeAuthoredFrameIndex(
            schemaVersion: 1,
            setVersion: "mind-eye-authored-frame-set/1",
            compilerVersion: "mind-eye-authored-frame-compiler/1.0.3",
            expectedManifestCount: 37,
            manifestSetSHA256: String(repeating: "0", count: 64),
            registrySHA256: String(repeating: "1", count: 64),
            toolchainLockSHA256: String(repeating: "2", count: 64),
            compilerConfigSHA256: String(repeating: "3", count: 64),
            phonemePoseMapSHA256: String(repeating: "4", count: 64),
            pronunciationOverridesSHA256: String(repeating: "5", count: 64),
            entries: entries,
            summary: summary
        )
    }
}
