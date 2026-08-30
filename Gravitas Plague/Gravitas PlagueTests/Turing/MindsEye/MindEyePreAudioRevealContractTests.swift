import XCTest

@testable import Gravitas_Plague

final class MindEyePreAudioRevealContractTests: XCTestCase {
    func testSpeechPlaybackWaitsForRevealAtAllSpokenBoundaries() throws {
        let source = try productionSource(
            "Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "await performMindEyeRevealLeadIn("
            ).count - 1,
            4
        )
        XCTAssertTrue(
            source.contains(
                "mindEyeRevealLeadInBeat: Duration = .milliseconds(300)"
            )
        )
        let reveal = try XCTUnwrap(
            source.range(of: "await performMindEyeRevealLeadIn(")
        )
        let playback = try XCTUnwrap(
            source.range(of: "let handle = try await playOneShot(",
                         range: reveal.upperBound ..< source.endIndex)
        )
        XCTAssertLessThan(reveal.lowerBound, playback.lowerBound)
    }

    func testPreviewStartsMotionButDefersMouthPlaybackUntilAudioStart() throws {
        let source = try productionSource(
            "Turing/MindsEye/MindEyePresentationCoordinator.swift"
        )
        XCTAssertTrue(source.contains("pendingRevealRequest == nil"))
        XCTAssertTrue(source.contains("idle portrait revealed before audio"))
        XCTAssertTrue(source.contains("motion=keepAlive mouth=rest"))
        XCTAssertTrue(source.contains("promotePreAudioReveal(to: context)"))
        XCTAssertTrue(source.contains("motionRestarted=false"))
    }

    func testPrerecordingFillerStagesTheAuthoredPortraitBeforeOrientation() throws {
        let source = try productionSource(
            "Turing/Conversation/TuringLiveConversationSessionCoordinator.swift"
        )
        let method = try XCTUnwrap(
            source.range(of: "func prepareForPrerecordingPreFiller(")
        )
        let remainder = source[method.lowerBound...]

        XCTAssertTrue(
            remainder.contains("TuringAuthoredPresentationPreparationHub.shared.publish")
        )
        XCTAssertTrue(
            remainder.contains("TuringSpokenPresentationRevealRequest(")
        )
        XCTAssertTrue(remainder.contains("source: source"))
        XCTAssertTrue(remainder.contains("orientationAudio=deviceFiller"))
        XCTAssertTrue(
            remainder.contains("pre-PR device filler visual requested")
        )
        XCTAssertTrue(
            remainder.contains(
                "motion=keepAlive blink=active mouth=restNonSpeech"
            )
        )
        XCTAssertTrue(
            remainder.contains(
                "microphoneContext=\\(resolvedMicrophoneContext)"
            )
        )
        XCTAssertTrue(
            remainder.contains("microphoneActionActivation=preFillerSelectable")
        )
        XCTAssertTrue(
            remainder.contains("context=upcomingPromptVoice")
        )
        XCTAssertFalse(remainder.contains("context=previousConversationVoice"))

        let microphoneStaging = try XCTUnwrap(
            remainder.range(of: "async let microphoneContext")
        )
        let visualPreparation = try XCTUnwrap(
            remainder.range(
                of: "TuringAuthoredPresentationPreparationHub.shared.publish"
            )
        )
        let microphoneJoin = try XCTUnwrap(
            remainder.range(of: "await microphoneContext")
        )
        XCTAssertLessThan(
            microphoneStaging.lowerBound,
            visualPreparation.lowerBound
        )
        XCTAssertLessThan(
            visualPreparation.lowerBound,
            microphoneJoin.lowerBound
        )
    }

    func testPreFillerMicrophoneIsSelectableWithoutGatingTheAuthoredPR() throws {
        let coordinator = try productionSource(
            "Turing/Conversation/TuringLiveConversationSessionCoordinator.swift"
        )
        let router = try productionSource(
            "Turing/Conversation/TuringStoryLiveMicrophoneActionRouter.swift"
        )

        XCTAssertTrue(coordinator.contains("selectable=true computeAhead=true"))
        XCTAssertTrue(coordinator.contains("selectedBeforeUpcomingPRStarted"))
        XCTAssertTrue(coordinator.contains("progressionHold=false"))
        XCTAssertTrue(coordinator.contains("waitForAuthoredMediaCompletion("))
        XCTAssertTrue(
            coordinator.contains("itemID: turn.seed.authoredMediaItemID")
        )
        XCTAssertFalse(coordinator.contains("preFillerMicrophonePreviewSurfaces"))
        XCTAssertFalse(router.contains("isPreFillerMicrophonePreview"))
        XCTAssertTrue(router.contains("canAcceptMicrophoneHold(surface: surface)"))

        let runner = try productionSource(
            "Turing/Flow/TuringAuthoredFlowRunner.swift"
        )
        XCTAssertTrue(
            runner.contains(
                "let preFillerPreparationTask: Task<Void, Never>?"
            )
        )
        XCTAssertTrue(
            runner.contains(
                "preFillerPreparationTask = Task { @MainActor in"
            )
        )
        XCTAssertFalse(
            runner.contains(
                "await liveConversationCoordinator\n" +
                    "                    .prepareForPrerecordingPreFiller"
            )
        )
        let preparation = try XCTUnwrap(
            runner.range(of: "preFillerPreparationTask = Task")
        )
        let leadIn = try XCTUnwrap(
            runner.range(of: "await route.runFixedLeadInIfNeeded")
        )
        let schedulingTurn = try XCTUnwrap(
            runner.range(of: "await Task.yield()")
        )
        XCTAssertLessThan(preparation.lowerBound, leadIn.lowerBound)
        XCTAssertLessThan(schedulingTurn.lowerBound, leadIn.lowerBound)
    }

    func testMicrophoneCTADrainsFromPRFrameOneUntilTwentySecondsRemain() {
        XCTAssertEqual(
            TuringPrerecordingMicrophoneCTAPolicy
                .transitionDuration(
                    prerecordingDurationSeconds: 19.9
                ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringPrerecordingMicrophoneCTAPolicy
                .transitionDuration(
                    prerecordingDurationSeconds: 20
                ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringPrerecordingMicrophoneCTAPolicy
                .transitionDuration(
                    prerecordingDurationSeconds: 24
                ),
            4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringPrerecordingMicrophoneCTAPolicy
                .transitionDuration(
                    prerecordingDurationSeconds: 45
                ),
            25,
            accuracy: 0.0001
        )

        let longStepCount = TuringPrerecordingMicrophoneCTAPolicy
            .transitionStepCount(prerecordingDurationSeconds: 45)
        XCTAssertEqual(
            TuringPrerecordingMicrophoneCTAPolicy.saturation(
                prerecordingDurationSeconds: 45,
                elapsedPlaybackSeconds: 0,
                stepCount: longStepCount
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringPrerecordingMicrophoneCTAPolicy.saturation(
                prerecordingDurationSeconds: 45,
                elapsedPlaybackSeconds: 5,
                stepCount: longStepCount
            ),
            0.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringPrerecordingMicrophoneCTAPolicy.saturation(
                prerecordingDurationSeconds: 45,
                elapsedPlaybackSeconds: 25,
                stepCount: longStepCount
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TuringPrerecordingMicrophoneCTAPolicy.saturation(
                prerecordingDurationSeconds: 19.9,
                elapsedPlaybackSeconds: 0,
                stepCount: 0
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testMicrophoneCTATimerIsPauseAwareAndDesaturatesSameArtwork() throws {
        let coordinator = try productionSource(
            "Turing/Conversation/TuringLiveConversationSessionCoordinator.swift"
        )
        XCTAssertTrue(coordinator.contains("case .authoredMediaPaused"))
        XCTAssertTrue(
            coordinator.contains("await pauseMicrophoneCTA(itemID: itemID)")
        )
        XCTAssertTrue(coordinator.contains("case .authoredMediaResumed"))
        XCTAssertTrue(
            coordinator.contains("await resumeMicrophoneCTA(itemID: itemID)")
        )
        XCTAssertTrue(coordinator.contains("accumulatedPlaybackSeconds"))
        XCTAssertTrue(coordinator.contains("transitionStartsAtFrame=1"))
        XCTAssertTrue(coordinator.contains("reason: \"linearDrainStep\""))

        let style = try productionSource(
            "Turing/Interaction/TuringStoryActionIconVisualStyle.swift"
        )
        XCTAssertTrue(style.contains("CIColorControls"))
        XCTAssertTrue(style.contains("kCIInputSaturationKey"))
        XCTAssertTrue(style.contains("microphoneCTAEmphasis.saturation"))
    }

    func testMissingVisualFallsThroughToAudioOnly() throws {
        let source = try productionSource(
            "Turing/Audio/TuringSpokenPresentationReveal.swift"
        )
        XCTAssertTrue(source.contains("guard continuations.isEmpty == false else"))
        XCTAssertTrue(source.contains("return .audioOnly"))
        XCTAssertTrue(source.contains("return nil"))
    }

    private func productionSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: mindEyeProjectRoot()
                .appendingPathComponent("Gravitas Plague/Gravitas Plague")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
