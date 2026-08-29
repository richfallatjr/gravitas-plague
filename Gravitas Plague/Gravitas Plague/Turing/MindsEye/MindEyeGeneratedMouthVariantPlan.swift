import Foundation

nonisolated struct MindEyeGeneratedMouthVariantPlan: Sendable, Equatable {
    let variantIndexByRun: ContiguousArray<Int>
    let tailRestVariantIndex: Int

    func selection(forRun index: Int, track: MindEyeGeneratedFrameTrack) -> MindEyeMouthSelection? {
        guard track.poseRuns.indices.contains(index), variantIndexByRun.indices.contains(index) else {
            return nil
        }
        return .init(pose: track.poseRuns[index].pose, variantIndex: variantIndexByRun[index])
    }

    var tailRestSelection: MindEyeMouthSelection {
        .init(pose: .rest, variantIndex: tailRestVariantIndex)
    }
}

nonisolated enum MindEyeGeneratedMouthVariantPlanBuilder {
    static func build(
        track: MindEyeGeneratedFrameTrack,
        counts: MindEyeMouthVariantCounts,
        rootSeed: UInt64
    ) -> Result<MindEyeGeneratedMouthVariantPlan, MindEyeFailure> {
        guard counts.allAreNonempty else {
            return .failure(failure("Every generated mouth pose requires a preloaded texture variant."))
        }
        var streams: [MindEyeMouthPose: MindEyeDeterministicRandom] = [
            .rest: .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "generated-mouth-rest")),
            .small: .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "generated-mouth-small")),
            .wide: .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "generated-mouth-wide")),
            .round: .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "generated-mouth-round")),
            .teeth: .init(seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "generated-mouth-teeth"))
        ]
        var history: [MindEyeMouthPose: Int] = [:]
        var variants = ContiguousArray<Int>()
        variants.reserveCapacity(track.poseRuns.count)
        for run in track.poseRuns {
            guard var random = streams[run.pose],
                  let selected = MindEyeVariantIndexSelector.select(
                    count: counts.count(for: run.pose),
                    avoiding: history[run.pose],
                    random: &random
                  ) else {
                return .failure(failure("Could not select a generated mouth variant."))
            }
            streams[run.pose] = random
            history[run.pose] = selected
            variants.append(selected)
        }
        var tail = MindEyeDeterministicRandom(
            seed: MindEyeMotionSeedFactory.substreamSeed(root: rootSeed, tag: "generated-mouth-tail-rest")
        )
        let tailRest = MindEyeVariantIndexSelector.select(
            count: counts.rest, avoiding: history[.rest], random: &tail
        ) ?? 0
        return .success(.init(variantIndexByRun: variants, tailRestVariantIndex: tailRest))
    }

    private static func failure(_ message: String) -> MindEyeFailure {
        MindEyeFailure(
            code: .generatedMouthVariantPlanInvalid,
            characterID: nil,
            vignetteID: nil,
            resourcePath: nil,
            message: message
        )
    }
}
