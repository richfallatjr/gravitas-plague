import Foundation

nonisolated struct MindEyeGeneratedPoseRun: Sendable, Equatable, Hashable {
    let startFrame: Int
    let endFrameExclusive: Int
    let pose: MindEyeMouthPose

    func contains(frameIndex: Int) -> Bool {
        startFrame <= frameIndex && frameIndex < endFrameExclusive
    }
}

nonisolated struct MindEyeGeneratedFrameTrack: Sendable, Equatable {
    let sampleRate: Int
    let sampleCount: Int
    let frameCount: Int
    let poseRuns: ContiguousArray<MindEyeGeneratedPoseRun>

    func runIndex(containingFrame frameIndex: Int, hint: Int? = nil) -> Int? {
        guard frameIndex >= 0, frameIndex < frameCount else { return nil }
        if let hint, poseRuns.indices.contains(hint),
           poseRuns[hint].contains(frameIndex: frameIndex) { return hint }
        var lower = 0
        var upper = poseRuns.count - 1
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            let run = poseRuns[middle]
            if frameIndex < run.startFrame { upper = middle - 1 }
            else if frameIndex >= run.endFrameExclusive { lower = middle + 1 }
            else { return middle }
        }
        return nil
    }
}

nonisolated extension TuringGeneratedMouthPose {
    var mindEyePose: MindEyeMouthPose {
        switch self {
        case .rest: .rest
        case .small: .small
        case .wide: .wide
        case .round: .round
        case .teeth: .teeth
        }
    }
}

nonisolated enum MindEyeGeneratedFrameTrackAdapter {
    static func adapt(
        _ source: TuringGeneratedSpeechFrameTrack
    ) -> Result<MindEyeGeneratedFrameTrack, MindEyeFailure> {
        guard source.sampleRate > 0, source.sampleCount > 0, source.frameCount > 0,
              source.framesPerSecond == 60, !source.poseRuns.isEmpty else {
            return .failure(failure("Generated speech frame track is invalid."))
        }
        var runs = ContiguousArray<MindEyeGeneratedPoseRun>()
        runs.reserveCapacity(source.poseRuns.count)
        var priorEnd = 0
        var priorPose: MindEyeMouthPose?
        for run in source.poseRuns {
            let pose = run.pose.mindEyePose
            guard run.startFrame == priorEnd, run.endFrameExclusive > run.startFrame,
                  pose != priorPose else {
                return .failure(failure("Generated pose runs are not compact and contiguous."))
            }
            runs.append(.init(
                startFrame: run.startFrame,
                endFrameExclusive: run.endFrameExclusive,
                pose: pose
            ))
            priorEnd = run.endFrameExclusive
            priorPose = pose
        }
        guard priorEnd == source.frameCount else {
            return .failure(failure("Generated pose runs do not cover the full timeline."))
        }
        return .success(.init(
            sampleRate: source.sampleRate,
            sampleCount: source.sampleCount,
            frameCount: source.frameCount,
            poseRuns: runs
        ))
    }

    private static func failure(_ message: String) -> MindEyeFailure {
        MindEyeFailure(
            code: .generatedFrameTrackInvalid,
            characterID: nil,
            vignetteID: nil,
            resourcePath: nil,
            message: message
        )
    }
}
