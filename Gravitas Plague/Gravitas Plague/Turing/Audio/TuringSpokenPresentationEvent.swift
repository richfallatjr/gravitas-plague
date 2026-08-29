import Foundation

nonisolated struct TuringSpokenPresentationRunIdentity:
    Sendable,
    Equatable,
    Hashable
{
    let playbackRunID: String
    let flowInstanceID: UUID
    let scriptPointID: String

    init(flowIdentity: TuringFlowIdentity) {
        playbackRunID = flowIdentity.playbackRunID
        flowInstanceID = flowIdentity.flowInstanceID
        scriptPointID = flowIdentity.scriptPointID
    }
}

nonisolated enum TuringSpokenPresentationSource:
    Sendable,
    Equatable
{
    case authored(
        prerecordingID: String,
        role: TuringAuthoredMediaItem.Role
    )
    case filler(clip: TuringFillerClipIdentity)
    case generated(segmentIndex: Int)

    var mediaIdentity: String {
        switch self {
        case .authored(let prerecordingID, let role):
            return "authored.\(role.rawValue).\(prerecordingID)"
        case .filler(let clip):
            return clip.stableMediaIdentity
        case .generated(let segmentIndex):
            return "generated.\(segmentIndex)"
        }
    }

    var participatesInResponseContinuity: Bool {
        switch self {
        case .filler, .generated: true
        case .authored: false
        }
    }
}

nonisolated struct TuringSpokenPresentationContext:
    Sendable,
    Equatable
{
    let run: TuringSpokenPresentationRunIdentity
    let playbackHandle: TuringAudioPlaybackHandle
    let speakerCharacterID: TuringConversationCharacterID
    let interactionSurface: StoryInteractionSurfaceID
    let source: TuringSpokenPresentationSource
    let clockOrigin: ContinuousClock.Instant
    let generatedSpeechFrameTrack: TuringGeneratedSpeechFrameTrack?

    init(
        run: TuringSpokenPresentationRunIdentity,
        playbackHandle: TuringAudioPlaybackHandle,
        speakerCharacterID: TuringConversationCharacterID,
        interactionSurface: StoryInteractionSurfaceID,
        source: TuringSpokenPresentationSource,
        clockOrigin: ContinuousClock.Instant,
        generatedSpeechFrameTrack: TuringGeneratedSpeechFrameTrack? = nil
    ) {
        self.run = run
        self.playbackHandle = playbackHandle
        self.speakerCharacterID = speakerCharacterID
        self.interactionSurface = interactionSurface
        self.source = source
        self.clockOrigin = clockOrigin
        self.generatedSpeechFrameTrack = generatedSpeechFrameTrack
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.run == rhs.run &&
            lhs.playbackHandle == rhs.playbackHandle &&
            lhs.speakerCharacterID == rhs.speakerCharacterID &&
            lhs.interactionSurface == rhs.interactionSurface &&
            lhs.source == rhs.source &&
            lhs.clockOrigin == rhs.clockOrigin &&
            Self.trackIdentity(lhs.generatedSpeechFrameTrack) ==
                Self.trackIdentity(rhs.generatedSpeechFrameTrack)
    }

    private static func trackIdentity(_ track: TuringGeneratedSpeechFrameTrack?) -> [Int]? {
        track.map { [$0.sampleRate, $0.sampleCount, $0.frameCount, $0.poseRuns.count] }
    }
}

nonisolated enum TuringSpokenPresentationEvent:
    Sendable,
    Equatable
{
    case started(context: TuringSpokenPresentationContext)
    case paused(
        context: TuringSpokenPresentationContext,
        instant: ContinuousClock.Instant,
        clock: TuringPauseAwarePlaybackClock,
        reason: String
    )
    case resumed(
        context: TuringSpokenPresentationContext,
        instant: ContinuousClock.Instant,
        clock: TuringPauseAwarePlaybackClock,
        reason: String
    )
    case authoredItemCompleted(
        context: TuringSpokenPresentationContext,
        clock: TuringPauseAwarePlaybackClock
    )
    case fillerItemCompleted(
        context: TuringSpokenPresentationContext,
        clock: TuringPauseAwarePlaybackClock,
        successfully: Bool
    )
    case generatedSegmentCompleted(
        context: TuringSpokenPresentationContext,
        clock: TuringPauseAwarePlaybackClock
    )
    case generatedTrackBecameAvailable(
        context: TuringSpokenPresentationContext,
        ticketID: UUID,
        timing: TuringGeneratedSpeechAnalysisTiming
    )
    case responseCompleted(run: TuringSpokenPresentationRunIdentity)
    case cancelled(
        context: TuringSpokenPresentationContext,
        clock: TuringPauseAwarePlaybackClock,
        reason: String
    )
    case failed(
        run: TuringSpokenPresentationRunIdentity,
        source: TuringSpokenPresentationSource?,
        requestID: UUID?,
        message: String
    )
}

nonisolated enum TuringSpokenPresentationContextResolution:
    Sendable,
    Equatable
{
    case resolved(TuringSpokenPresentationContext)
    case suppressed(reason: String)
}

nonisolated enum TuringSpokenPresentationContextResolver {
    static func authored(
        item: TuringAuthoredMediaItem,
        flowIdentity: TuringFlowIdentity,
        playbackHandle: TuringAudioPlaybackHandle,
        clockOrigin: ContinuousClock.Instant
    ) -> TuringSpokenPresentationContextResolution {
        guard playbackHandle.runID == flowIdentity.playbackRunID else {
            return .suppressed(reason: "runIdentityMismatch")
        }
        guard let speaker = TuringConversationCharacterID(
            rawValue: item.speakerCharacterID
        ) else {
            return .suppressed(
                reason: "unknownAuthoredSpeaker.\(item.speakerCharacterID)"
            )
        }
        if let catalogEntry = item.liveConversationCatalogEntry {
            guard catalogEntry.speakerCharacterID == speaker else {
                return .suppressed(
                    reason:
                        "authoredSpeakerCatalogMismatch." +
                        "descriptor=\(speaker.rawValue)." +
                        "catalog=\(catalogEntry.speakerCharacterID.rawValue)"
                )
            }
            guard catalogEntry.interactionSurface ==
                    flowIdentity.interactionSurface else {
                return .suppressed(
                    reason:
                        "authoredSurfaceCatalogMismatch." +
                        "flow=\(flowIdentity.interactionSurface.rawValue)." +
                        "catalog=\(catalogEntry.interactionSurface.rawValue)"
                )
            }
        }
        return .resolved(
            TuringSpokenPresentationContext(
                run: .init(flowIdentity: flowIdentity),
                playbackHandle: playbackHandle,
                speakerCharacterID: speaker,
                interactionSurface: flowIdentity.interactionSurface,
                source: .authored(
                    prerecordingID: item.id,
                    role: item.role
                ),
                clockOrigin: clockOrigin,
                generatedSpeechFrameTrack: nil
            )
        )
    }

    static func generated(
        segmentIndex: Int,
        preparedClip: TuringGeneratedPlaybackFileStore.PreparedClip,
        flowIdentity: TuringFlowIdentity,
        playbackHandle: TuringAudioPlaybackHandle,
        clockOrigin: ContinuousClock.Instant
    ) -> TuringSpokenPresentationContextResolution {
        guard playbackHandle.runID == flowIdentity.playbackRunID else {
            return .suppressed(reason: "runIdentityMismatch")
        }
        guard let speaker = TuringConversationCharacterID(
            rawValue: flowIdentity.characterID
        ) else {
            return .suppressed(
                reason: "unknownGeneratedSpeaker.\(flowIdentity.characterID)"
            )
        }
        return .resolved(
            TuringSpokenPresentationContext(
                run: .init(flowIdentity: flowIdentity),
                playbackHandle: playbackHandle,
                speakerCharacterID: speaker,
                interactionSurface: flowIdentity.interactionSurface,
                source: .generated(segmentIndex: segmentIndex),
                clockOrigin: clockOrigin,
                generatedSpeechFrameTrack: preparedClip.generatedVisualAnalysis?.frameTrack
            )
        )
    }

    static func filler(
        clip: TuringFillerClipDescriptor,
        expectedSpeaker: TuringConversationCharacterID,
        flowIdentity: TuringFlowIdentity,
        playbackHandle: TuringAudioPlaybackHandle,
        clockOrigin: ContinuousClock.Instant
    ) -> TuringSpokenPresentationContextResolution {
        guard playbackHandle.runID == flowIdentity.playbackRunID else {
            return .suppressed(reason: "runIdentityMismatch")
        }
        guard clip.identity.speakerCharacterID == expectedSpeaker else {
            return .suppressed(
                reason: "fillerSpeakerMismatch.expected=\(expectedSpeaker.rawValue)." +
                    "descriptor=\(clip.identity.speakerCharacterID.rawValue)"
            )
        }
        return .resolved(
            TuringSpokenPresentationContext(
                run: .init(flowIdentity: flowIdentity),
                playbackHandle: playbackHandle,
                speakerCharacterID: expectedSpeaker,
                interactionSurface: flowIdentity.interactionSurface,
                source: .filler(clip: clip.identity),
                clockOrigin: clockOrigin,
                generatedSpeechFrameTrack: nil
            )
        )
    }
}
