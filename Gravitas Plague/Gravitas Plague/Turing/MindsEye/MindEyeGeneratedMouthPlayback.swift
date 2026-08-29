import Foundation

nonisolated struct MindEyeGeneratedMouthPlaybackContext: Sendable {
    let presentationKey: MindEyePresentationKey
    let segmentIndex: Int
    let track: MindEyeGeneratedFrameTrack
    let clock: TuringPauseAwarePlaybackClock
    let rootSeed: UInt64
    let explicitTestSeed: UInt64?

    var resolvedRootSeed: UInt64 { explicitTestSeed ?? rootSeed }
}

nonisolated struct MindEyeGeneratedMouthUpdate: Sendable, Equatable {
    let segmentIndex: Int
    let frameIndex: Int?
    let runIndex: Int?
    let selection: MindEyeMouthSelection
    let isPastEnd: Bool
}

nonisolated struct MindEyeGeneratedPlaybackSnapshot: Sendable, Equatable {
    let isInstalled: Bool
    let isPaused: Bool
    let segmentIndex: Int?
    let sampleRate: Int?
    let sampleCount: Int?
    let frameCount: Int?
    let poseRunCount: Int?
    let frameIndex: Int?
    let runIndex: Int?
    let pose: MindEyeMouthPose?
    let variantIndex: Int?
    let isPastEnd: Bool
}

@MainActor
protocol MindEyeGeneratedMouthPlaybackSink: AnyObject {
    func receiveMindEyeGeneratedMouthUpdate(_ update: MindEyeGeneratedMouthUpdate)
    func receiveMindEyeGeneratedMouthFailure(_ failure: MindEyeFailure)
}

@MainActor
protocol MindEyeGeneratedMouthControlling: AnyObject {
    func startGeneratedMouthPlayback(
        context: MindEyeGeneratedMouthPlaybackContext
    ) -> Result<Void, MindEyeFailure>
    func updateGeneratedMouthClock(
        _ clock: TuringPauseAwarePlaybackClock,
        paused: Bool,
        instant: ContinuousClock.Instant?,
        reason: String
    )
    func stopGeneratedMouthPlayback(reason: String, resetToRest: Bool)
}

nonisolated struct MindEyeGeneratedFramePlaybackSession: Sendable {
    let presentationKey: MindEyePresentationKey
    let segmentIndex: Int
    let track: MindEyeGeneratedFrameTrack
    let variantPlan: MindEyeGeneratedMouthVariantPlan
    private(set) var clock: TuringPauseAwarePlaybackClock
    private(set) var currentFrameIndex: Int?
    private(set) var currentRunIndex: Int?
    private(set) var currentSelection: MindEyeMouthSelection?
    private(set) var deliveredPastEnd = false

    mutating func replaceClock(_ value: TuringPauseAwarePlaybackClock) { clock = value }

    mutating func sample(
        at instant: ContinuousClock.Instant
    ) -> Result<MindEyeGeneratedMouthUpdate?, MindEyeFailure> {
        switch MindEyeGeneratedFrameClockMapper.position(clock: clock, at: instant, track: track) {
        case .failure(let failure): return .failure(failure)
        case .success(.pastEnd):
            let selection = variantPlan.tailRestSelection
            if deliveredPastEnd, currentSelection == selection { return .success(nil) }
            deliveredPastEnd = true
            currentFrameIndex = nil
            currentRunIndex = nil
            currentSelection = selection
            return .success(.init(
                segmentIndex: segmentIndex,
                frameIndex: nil,
                runIndex: nil,
                selection: selection,
                isPastEnd: true
            ))
        case .success(.frame(let frameIndex)):
            deliveredPastEnd = false
            guard let runIndex = track.runIndex(containingFrame: frameIndex, hint: currentRunIndex),
                  let selection = variantPlan.selection(forRun: runIndex, track: track) else {
                return .failure(MindEyeFailure(
                    code: .generatedMouthPlaybackInvalid,
                    characterID: nil,
                    vignetteID: nil,
                    resourcePath: nil,
                    message: "Could not resolve the generated pose run for the current frame."
                ))
            }
            currentFrameIndex = frameIndex
            guard currentRunIndex != runIndex || currentSelection != selection else { return .success(nil) }
            currentRunIndex = runIndex
            currentSelection = selection
            return .success(.init(
                segmentIndex: segmentIndex,
                frameIndex: frameIndex,
                runIndex: runIndex,
                selection: selection,
                isPastEnd: false
            ))
        }
    }
}
