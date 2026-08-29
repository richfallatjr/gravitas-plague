import Foundation

nonisolated struct MindEyeMouthVariantCounts: Sendable, Equatable {
    let rest: Int
    let small: Int
    let wide: Int
    let round: Int
    let teeth: Int

    func count(for pose: MindEyeMouthPose) -> Int {
        switch pose {
        case .rest: rest
        case .small: small
        case .wide: wide
        case .round: round
        case .teeth: teeth
        }
    }

    var allAreNonempty: Bool {
        rest > 0 && small > 0 && wide > 0 && round > 0 && teeth > 0
    }
}

nonisolated struct MindEyeAuthoredMouthRandomStreams: Sendable, Equatable {
    var rest: MindEyeDeterministicRandom
    var small: MindEyeDeterministicRandom
    var wide: MindEyeDeterministicRandom
    var round: MindEyeDeterministicRandom
    var teeth: MindEyeDeterministicRandom
    var tailRest: MindEyeDeterministicRandom

    init(rootSeed: UInt64) {
        rest = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "authored-mouth-rest"))
        small = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "authored-mouth-small"))
        wide = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "authored-mouth-wide"))
        round = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "authored-mouth-round"))
        teeth = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "authored-mouth-teeth"))
        tailRest = .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "authored-mouth-tail-rest"))
    }

    mutating func withStream<Result>(
        for pose: MindEyeMouthPose,
        _ body: (inout MindEyeDeterministicRandom) -> Result
    ) -> Result {
        switch pose {
        case .rest: body(&rest)
        case .small: body(&small)
        case .wide: body(&wide)
        case .round: body(&round)
        case .teeth: body(&teeth)
        }
    }
}

nonisolated struct MindEyeAuthoredMouthVariantHistory: Sendable, Equatable {
    var rest: Int?
    var small: Int?
    var wide: Int?
    var round: Int?
    var teeth: Int?

    subscript(pose: MindEyeMouthPose) -> Int? {
        get {
            switch pose {
            case .rest: rest
            case .small: small
            case .wide: wide
            case .round: round
            case .teeth: teeth
            }
        }
        set {
            switch pose {
            case .rest: rest = newValue
            case .small: small = newValue
            case .wide: wide = newValue
            case .round: round = newValue
            case .teeth: teeth = newValue
            }
        }
    }
}

nonisolated struct MindEyeAuthoredMouthVariantPlan: Sendable, Equatable {
    let variantIndexByRun: ContiguousArray<Int>
    let tailRestVariantIndex: Int

    func selection(
        forRun index: Int,
        track: MindEyeAuthoredFrameTrack
    ) -> MindEyeMouthSelection? {
        guard track.poseRuns.indices.contains(index),
              variantIndexByRun.indices.contains(index) else { return nil }
        return MindEyeMouthSelection(
            pose: track.poseRuns[index].pose,
            variantIndex: variantIndexByRun[index]
        )
    }

    var tailRestSelection: MindEyeMouthSelection {
        MindEyeMouthSelection(pose: .rest, variantIndex: tailRestVariantIndex)
    }
}

nonisolated enum MindEyeAuthoredMouthVariantPlanBuilder {
    static func build(
        track: MindEyeAuthoredFrameTrack,
        counts: MindEyeMouthVariantCounts,
        rootSeed: UInt64
    ) -> Result<MindEyeAuthoredMouthVariantPlan, MindEyeFailure> {
        guard counts.allAreNonempty else {
            return .failure(failure(track, "Every authored mouth pose requires a preloaded texture variant."))
        }
        var streams = MindEyeAuthoredMouthRandomStreams(rootSeed: rootSeed)
        var history = MindEyeAuthoredMouthVariantHistory()
        var variants = ContiguousArray<Int>()
        variants.reserveCapacity(track.poseRuns.count)
        for run in track.poseRuns {
            let selected = streams.withStream(for: run.pose) { random in
                MindEyeVariantIndexSelector.select(
                    count: counts.count(for: run.pose),
                    avoiding: history[run.pose],
                    random: &random
                )
            }
            guard let selected else {
                return .failure(failure(track, "Could not select a validated authored mouth variant."))
            }
            history[run.pose] = selected
            variants.append(selected)
        }
        let tailRest = MindEyeVariantIndexSelector.select(
            count: counts.rest,
            avoiding: history[.rest],
            random: &streams.tailRest
        ) ?? 0
        return .success(.init(
            variantIndexByRun: variants,
            tailRestVariantIndex: tailRest
        ))
    }

    private static func failure(
        _ track: MindEyeAuthoredFrameTrack,
        _ message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: .authoredMouthVariantPlanInvalid,
            characterID: track.descriptor.speakerCharacterID,
            vignetteID: nil,
            resourcePath: track.descriptor.manifestResourcePath,
            message: message
        )
    }
}
