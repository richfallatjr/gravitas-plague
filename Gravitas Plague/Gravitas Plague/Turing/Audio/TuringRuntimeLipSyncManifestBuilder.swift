import Foundation

nonisolated struct TuringRuntimeLipSyncManifestTiming: Sendable, Equatable {
    let engineColdStartNanoseconds: UInt64?
    let queueDelayNanoseconds: UInt64
    let preprocessingNanoseconds: UInt64
    let firstPassNanoseconds: UInt64?
    let secondPassNanoseconds: UInt64?
    let mappingNanoseconds: UInt64
    let totalAnalysisNanoseconds: UInt64
    let fallbackReason: String?
}

nonisolated enum TuringRuntimeLipSyncManifestValidator {
    static func failures(
        _ manifest: TuringRuntimeLipSyncManifest,
        against input: TuringRuntimeLipSyncInput,
        sourcePCM_SHA256: String
    ) -> [String] {
        var failures: [String] = []
        if manifest.schemaVersion != 1 { failures.append("schemaVersion") }
        if manifest.generatorID.isEmpty || manifest.generatorVersion.isEmpty {
            failures.append("generatorIdentity")
        }
        if manifest.identity != input.identity { failures.append("segmentIdentity") }
        if manifest.sourcePCM_SHA256 != sourcePCM_SHA256 { failures.append("pcmIdentity") }
        if manifest.sampleRate != input.sampleRate ||
            manifest.sampleCount != input.sampleCountPerChannel {
            failures.append("sourceTimeline")
        }
        if manifest.framesPerSecond != 60 { failures.append("frameRate") }
        let expected = try? TuringGeneratedSpeechFrameTrack.frameCount(
            sampleCount: input.sampleCountPerChannel,
            sampleRate: input.sampleRate,
            framesPerSecond: 60
        )
        if manifest.frameCount != expected { failures.append("frameCount") }
        if manifest.poseRuns.isEmpty || manifest.poseRuns.first?.startFrame != 0 ||
            manifest.poseRuns.last?.endFrameExclusive != manifest.frameCount {
            failures.append("coverage")
        }
        var priorEnd = 0
        var priorPose: TuringGeneratedMouthPose?
        for run in manifest.poseRuns {
            if run.startFrame != priorEnd || run.endFrameExclusive <= run.startFrame ||
                run.pose == priorPose {
                failures.append("sparseRuns")
                break
            }
            priorEnd = run.endFrameExclusive
            priorPose = run.pose
        }
        return failures
    }
}

nonisolated struct TuringRuntimeLipSyncManifestBuilder: Sendable {
    let generatorID: String
    let generatorVersion: String

    func build(
        input: TuringRuntimeLipSyncInput,
        sourcePCM: TuringRuntimeLipSyncPreparedPCM,
        normalizedText: TuringRuntimeLipSyncNormalizedText,
        refinedPhones: TuringRuntimeLipSyncRefinementResult,
        quality: TuringRuntimeLipSyncQuality,
        timing: TuringRuntimeLipSyncManifestTiming
    ) throws -> TuringRuntimeLipSyncManifest {
        let frameCount = try TuringGeneratedSpeechFrameTrack.frameCount(
            sampleCount: input.sampleCountPerChannel,
            sampleRate: input.sampleRate,
            framesPerSecond: TuringRuntimeLipSyncManifest.requiredFramesPerSecond
        )
        var poses = ContiguousArray<TuringGeneratedMouthPose>(
            repeating: .rest,
            count: frameCount
        )
        for frame in 0..<frameCount {
            let start = frame * input.sampleRate / 60
            let end = min(
                input.sampleCountPerChannel,
                ((frame + 1) * input.sampleRate + 59) / 60
            )
            poses[frame] = decidePose(
                start: start,
                end: max(start + 1, end),
                phones: refinedPhones.phones
            )
        }
        applyCoarticulation(to: &poses)
        repairMinimumHolds(in: &poses)
        let runs = coalesce(poses)
        let diagnostics = TuringRuntimeLipSyncDiagnostics(
            exactTextPresent: !input.exactSourceText.isEmpty,
            normalizedWordCount: normalizedText.normalizedWords.count,
            unresolvedWordCount: normalizedText.unresolvedWords.count,
            phoneSegmentCount: refinedPhones.phones.count,
            alignmentFrameRate: 100,
            globalBoundaryOffsetFrames: refinedPhones.globalOffsetFrames,
            queueDelayNanoseconds: timing.queueDelayNanoseconds,
            engineColdStartNanoseconds: timing.engineColdStartNanoseconds,
            preprocessingNanoseconds: timing.preprocessingNanoseconds,
            firstPassNanoseconds: timing.firstPassNanoseconds,
            secondPassNanoseconds: timing.secondPassNanoseconds,
            mappingNanoseconds: timing.mappingNanoseconds,
            totalAnalysisNanoseconds: timing.totalAnalysisNanoseconds,
            fallbackReason: timing.fallbackReason
        )
        return TuringRuntimeLipSyncManifest(
            generatorID: generatorID,
            generatorVersion: generatorVersion,
            quality: quality,
            identity: input.identity,
            sourcePCM_SHA256: sourcePCM.sourcePCM_SHA256,
            sampleRate: input.sampleRate,
            sampleCount: input.sampleCountPerChannel,
            frameCount: frameCount,
            poseRuns: runs,
            diagnostics: diagnostics
        )
    }

    private func decidePose(
        start: Int,
        end: Int,
        phones: [TuringRuntimeLipSyncSourcePhoneSpan]
    ) -> TuringGeneratedMouthPose {
        var overlap: [TuringGeneratedMouthPose: Int] = [.rest: end - start]
        for phone in phones {
            let amount = max(
                0,
                min(end, phone.endSampleExclusive) - max(start, phone.startSample)
            )
            guard amount > 0 else { continue }
            overlap[phone.pose, default: 0] += amount
            overlap[.rest, default: 0] -= amount
        }
        let maximum = overlap.values.max() ?? 0
        let tied = overlap.filter { $0.value == maximum }.map(\.key)
        if tied.count == 1 { return tied[0] }
        let center = start + (end - start) / 2
        if let centered = phones.first(where: {
            $0.startSample <= center && center < $0.endSampleExclusive
        })?.pose, tied.contains(centered) {
            return centered
        }
        for pose in [TuringGeneratedMouthPose.teeth, .round, .small, .wide, .rest]
        where tied.contains(pose) { return pose }
        return .rest
    }

    private func applyCoarticulation(
        to poses: inout ContiguousArray<TuringGeneratedMouthPose>
    ) {
        guard poses.count > 1 else { return }
        let original = poses
        for index in 0..<(poses.count - 1) {
            let current = original[index]
            let next = original[index + 1]
            if current != .rest, next != .rest,
               (next == .round || next == .teeth), current != next {
                poses[index] = next
            }
        }
    }

    private func repairMinimumHolds(
        in poses: inout ContiguousArray<TuringGeneratedMouthPose>
    ) {
        let minimum: [TuringGeneratedMouthPose: Int] = [
            .rest: 1, .small: 2, .wide: 3, .round: 3, .teeth: 2
        ]
        var changed = true
        while changed {
            changed = false
            let runs = coalesce(poses)
            for run in runs where run.frameCount < (minimum[run.pose] ?? 1) {
                let left = run.startFrame > 0 ? poses[run.startFrame - 1] : nil
                let right = run.endFrameExclusive < poses.count ? poses[run.endFrameExclusive] : nil
                if run.pose == .rest || left == .rest || right == .rest { continue }
                let replacement = left == right ? left : (left ?? right)
                guard let replacement, replacement != .rest else { continue }
                for frame in run.startFrame..<run.endFrameExclusive { poses[frame] = replacement }
                changed = true
                break
            }
        }
    }

    private func coalesce(
        _ poses: ContiguousArray<TuringGeneratedMouthPose>
    ) -> [TuringGeneratedMouthPoseRun] {
        guard let first = poses.first else { return [] }
        var runs: [TuringGeneratedMouthPoseRun] = []
        var start = 0
        var pose = first
        for index in 1..<poses.count where poses[index] != pose {
            runs.append(.init(startFrame: start, endFrameExclusive: index, pose: pose))
            start = index
            pose = poses[index]
        }
        runs.append(.init(startFrame: start, endFrameExclusive: poses.count, pose: pose))
        return runs
    }
}
