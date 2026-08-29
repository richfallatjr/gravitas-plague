import Foundation

nonisolated struct MindEyeAuthoredMouthPlaybackContext: Sendable {
    let presentationKey: MindEyePresentationKey
    let track: MindEyeAuthoredFrameTrack
    let clock: TuringPauseAwarePlaybackClock
    let rootSeed: UInt64
    let explicitTestSeed: UInt64?

    var resolvedRootSeed: UInt64 { explicitTestSeed ?? rootSeed }
}

nonisolated struct MindEyeAuthoredMouthUpdate: Sendable, Equatable {
    let prID: String
    let trackFrameIndex: Int?
    let poseRunIndex: Int?
    let selection: MindEyeMouthSelection
    let isPastEnd: Bool
}

@MainActor
protocol MindEyeAuthoredMouthPlaybackSink: AnyObject {
    func receiveMindEyeAuthoredMouthUpdate(_ update: MindEyeAuthoredMouthUpdate)
    func receiveMindEyeAuthoredMouthFailure(_ failure: MindEyeFailure)
}

nonisolated struct MindEyeAuthoredFramePlaybackSession: Sendable {
    let presentationKey: MindEyePresentationKey
    let track: MindEyeAuthoredFrameTrack
    let variantPlan: MindEyeAuthoredMouthVariantPlan
    private(set) var clock: TuringPauseAwarePlaybackClock
    private(set) var currentFrameIndex: Int?
    private(set) var currentRunIndex: Int?
    private(set) var currentSelection: MindEyeMouthSelection?
    private(set) var deliveredPastEnd = false

    init(
        presentationKey: MindEyePresentationKey,
        track: MindEyeAuthoredFrameTrack,
        clock: TuringPauseAwarePlaybackClock,
        variantPlan: MindEyeAuthoredMouthVariantPlan
    ) {
        self.presentationKey = presentationKey
        self.track = track
        self.clock = clock
        self.variantPlan = variantPlan
    }

    mutating func replaceClock(_ value: TuringPauseAwarePlaybackClock) {
        clock = value
    }

    mutating func sample(
        at instant: ContinuousClock.Instant
    ) -> Result<MindEyeAuthoredMouthUpdate?, MindEyeFailure> {
        switch MindEyeAuthoredFrameClockMapper.position(
            clock: clock,
            at: instant,
            track: track
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(.pastEnd):
            let selection = variantPlan.tailRestSelection
            if deliveredPastEnd, currentSelection == selection { return .success(nil) }
            deliveredPastEnd = true
            currentFrameIndex = nil
            currentRunIndex = nil
            currentSelection = selection
            return .success(.init(
                prID: track.descriptor.prID,
                trackFrameIndex: nil,
                poseRunIndex: nil,
                selection: selection,
                isPastEnd: true
            ))
        case .success(.frame(let frameIndex)):
            deliveredPastEnd = false
            guard let runIndex = track.runIndex(
                containingFrame: frameIndex,
                hint: currentRunIndex
            ), let selection = variantPlan.selection(forRun: runIndex, track: track) else {
                return .failure(MindEyeFailure(
                    code: .authoredFramePlaybackInvalid,
                    characterID: track.descriptor.speakerCharacterID,
                    vignetteID: nil,
                    resourcePath: track.descriptor.manifestResourcePath,
                    message: "Could not resolve authored pose run for the current frame."
                ))
            }
            currentFrameIndex = frameIndex
            guard currentRunIndex != runIndex || currentSelection != selection else {
                return .success(nil)
            }
            currentRunIndex = runIndex
            currentSelection = selection
            return .success(.init(
                prID: track.descriptor.prID,
                trackFrameIndex: frameIndex,
                poseRunIndex: runIndex,
                selection: selection,
                isPastEnd: false
            ))
        }
    }
}
