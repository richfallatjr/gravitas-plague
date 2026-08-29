import XCTest

@testable import Gravitas_Plague

final class MindEyePresentationEligibilityTests: XCTestCase {
    private let policy = MindEyeDefaultPresentationEligibility()

    func testAllEightExplicitExclusionsAreSuppressed() {
        XCTAssertEqual(
            MindEyeDefaultPresentationEligibility.explicitlyExcludedPrerecordingIDs.count,
            8
        )
        for identifier in MindEyeDefaultPresentationEligibility.explicitlyExcludedPrerecordingIDs {
            guard case .suppressed(let reason) = policy.decision(
                for: context(prerecordingID: identifier)
            ) else {
                XCTFail("Expected explicit exclusion: \(identifier)")
                continue
            }
            XCTAssertEqual(reason, "explicitlyExcludedPrerecording.\(identifier)")
        }
    }

    func testEligiblePrimaryAndAuthoredBridgeAreAllowed() {
        XCTAssertEqual(
            policy.decision(for: context(role: .primaryPrerecording)),
            .eligible
        )
        XCTAssertEqual(
            policy.decision(for: context(role: .authoredBridge)),
            .eligible
        )
    }

    func testOpeningCueAndClosingBumperAreSuppressed() {
        for role in [TuringAuthoredMediaItem.Role.openingCue, .closingBumper] {
            guard case .suppressed(let reason) = policy.decision(
                for: context(role: role)
            ) else {
                XCTFail("Expected role suppression: \(role.rawValue)")
                continue
            }
            XCTAssertEqual(reason, "nonPortraitAuthoredRole.\(role.rawValue)")
        }
    }

    func testGeneratedSpeechIsAllowedForActualSpeaker() {
        let generated = context(
            speaker: .rich,
            source: .generated(segmentIndex: 3)
        )
        XCTAssertEqual(policy.decision(for: generated), .eligible)
        XCTAssertEqual(generated.speakerCharacterID, .rich)
    }

    func testRichWalkieEligibilityDoesNotBecomeBigMike() {
        let rich = context(speaker: .rich)
        XCTAssertEqual(policy.decision(for: rich), .eligible)
        XCTAssertEqual(rich.speakerCharacterID, .rich)
        XCTAssertNotEqual(rich.speakerCharacterID, .bigMike)
    }

    private func context(
        prerecordingID: String = "eligible.test.001",
        role: TuringAuthoredMediaItem.Role = .primaryPrerecording,
        speaker: TuringConversationCharacterID = .bigMike,
        surface: StoryInteractionSurfaceID = .walkie,
        source: TuringSpokenPresentationSource? = nil
    ) -> TuringSpokenPresentationContext {
        let runID = "run.\(prerecordingID)"
        let flow = TuringFlowIdentity(
            scriptPointID: "test.script",
            characterID: speaker.rawValue,
            prerecordingID: prerecordingID,
            voicePromptID: "test.voice",
            interactionSurface: surface,
            playbackRunID: runID
        )
        return TuringSpokenPresentationContext(
            run: .init(flowIdentity: flow),
            playbackHandle: TuringAudioPlaybackHandle(
                id: UUID(),
                requestID: UUID(),
                runID: runID,
                route: .storyWalkie
            ),
            speakerCharacterID: speaker,
            interactionSurface: surface,
            source: source ?? .authored(
                prerecordingID: prerecordingID,
                role: role
            ),
            clockOrigin: .now
        )
    }
}
