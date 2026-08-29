import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringFillerPresentationContractTests: XCTestCase {
    func testWeightedSelectionUsesUniqueDescriptorsWithoutExpansion() {
        let first = descriptor(id: "first", weight: 2)
        let second = descriptor(id: "second", weight: 3)
        XCTAssertEqual(
            TuringWeightedFillerSelector.select(
                clips: [first, second],
                avoiding: nil,
                draw: 0
            )?.identity.fillerID,
            "first"
        )
        XCTAssertEqual(
            TuringWeightedFillerSelector.select(
                clips: [first, second],
                avoiding: nil,
                draw: 2
            )?.identity.fillerID,
            "second"
        )
        XCTAssertEqual(
            TuringWeightedFillerSelector.select(
                clips: [first, second],
                avoiding: "first",
                draw: 0
            )?.identity.fillerID,
            "second"
        )
    }

    func testFillerContextUsesFlowCharacterAndActualClockOrigin() {
        let clip = descriptor(id: "big_mike.filler.test.001", weight: 1)
        let flow = TuringFlowIdentity(
            scriptPointID: "test.filler",
            characterID: TuringConversationCharacterID.bigMike.rawValue,
            prerecordingID: "test.pr",
            voicePromptID: "big_mike_base_clone_v1",
            playbackRunID: "test.filler.run"
        )
        let handle = TuringAudioPlaybackHandle(
            id: UUID(),
            requestID: UUID(),
            runID: flow.playbackRunID,
            route: .storyWalkie
        )
        let origin = ContinuousClock.now
        let result = TuringSpokenPresentationContextResolver.filler(
            clip: clip,
            expectedSpeaker: .bigMike,
            flowIdentity: flow,
            playbackHandle: handle,
            clockOrigin: origin
        )
        guard case .resolved(let context) = result else {
            return XCTFail("Expected tracked filler context.")
        }
        XCTAssertEqual(context.speakerCharacterID, .bigMike)
        XCTAssertEqual(context.clockOrigin, origin)
        XCTAssertEqual(context.responsePresentationKey?.playbackRunID, flow.playbackRunID)
        guard case .filler(let identity) = context.source else {
            return XCTFail("Expected filler source.")
        }
        XCTAssertEqual(identity.fillerID, clip.identity.fillerID)
    }

    func testFillerSpeakerMismatchIsAudioOnlySuppression() {
        let clip = descriptor(id: "big_mike.filler.test.001", weight: 1)
        let flow = TuringFlowIdentity(
            scriptPointID: "test.filler",
            characterID: TuringConversationCharacterID.rich.rawValue,
            prerecordingID: "test.pr",
            voicePromptID: "rich",
            interactionSurface: .dadFrame,
            playbackRunID: "test.filler.run"
        )
        let handle = TuringAudioPlaybackHandle(
            id: UUID(), requestID: UUID(), runID: flow.playbackRunID, route: .richHeadTracked
        )
        guard case .suppressed(let reason) = TuringSpokenPresentationContextResolver.filler(
            clip: clip,
            expectedSpeaker: .rich,
            flowIdentity: flow,
            playbackHandle: handle,
            clockOrigin: .now
        ) else {
            return XCTFail("Expected exact-speaker suppression.")
        }
        XCTAssertTrue(reason.contains("fillerSpeakerMismatch"))
    }

    private func descriptor(id: String, weight: Int) -> TuringFillerClipDescriptor {
        TuringFillerClipDescriptor(
            identity: TuringFillerClipIdentity(
                fillerID: id,
                speakerCharacterID: .bigMike,
                audioResourcePath: "Turing/Audio/big-mike-filler/test.mp3",
                audioSHA256: String(repeating: "a", count: 64),
                trackResourcePath: "Turing/MindsEye/Fillers/Tracks/\(id).fillerframes.json",
                trackSHA256: String(repeating: "b", count: 64)
            ),
            fileURL: URL(fileURLWithPath: "/tmp/test.mp3"),
            weight: weight,
            authoringMode: .manualTranscript
        )
    }
}
