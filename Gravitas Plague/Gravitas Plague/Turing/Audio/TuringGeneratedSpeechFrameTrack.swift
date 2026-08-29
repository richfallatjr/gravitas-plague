import Foundation

nonisolated enum TuringGeneratedMouthPose: UInt8, Sendable, Equatable, Hashable, CaseIterable {
    case rest = 1
    case small = 2
    case wide = 4
    case round = 8
    case teeth = 16
}

nonisolated struct TuringGeneratedMouthPoseRun: Sendable, Equatable, Hashable {
    let startFrame: Int
    let endFrameExclusive: Int
    let pose: TuringGeneratedMouthPose

    var frameCount: Int { endFrameExclusive - startFrame }

    func contains(frameIndex: Int) -> Bool {
        startFrame <= frameIndex && frameIndex < endFrameExclusive
    }
}

nonisolated struct TuringGeneratedSpeechFrameTrack: Sendable, Equatable {
    let sampleRate: Int
    let sampleCount: Int
    let framesPerSecond: Int
    let frameCount: Int
    private let poseBits: ContiguousArray<UInt8>
    let poseRuns: ContiguousArray<TuringGeneratedMouthPoseRun>

    init(
        sampleRate: Int,
        sampleCount: Int,
        framesPerSecond: Int = 60,
        poseBits: ContiguousArray<UInt8>,
        poseRuns: ContiguousArray<TuringGeneratedMouthPoseRun>
    ) throws {
        guard sampleRate > 0, sampleCount > 0, framesPerSecond == 60,
              !poseBits.isEmpty, !poseRuns.isEmpty else {
            throw TuringGeneratedSpeechAnalysisError.invalidTrack
        }
        let expected = try Self.frameCount(
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            framesPerSecond: framesPerSecond
        )
        guard poseBits.count == expected,
              poseBits.allSatisfy({ TuringGeneratedMouthPose(rawValue: $0) != nil }),
              poseRuns.first?.startFrame == 0,
              poseRuns.last?.endFrameExclusive == expected else {
            throw TuringGeneratedSpeechAnalysisError.invalidTrack
        }
        var priorEnd = 0
        var priorPose: TuringGeneratedMouthPose?
        for run in poseRuns {
            guard run.startFrame == priorEnd, run.endFrameExclusive > run.startFrame,
                  run.pose != priorPose else {
                throw TuringGeneratedSpeechAnalysisError.invalidTrack
            }
            priorEnd = run.endFrameExclusive
            priorPose = run.pose
        }
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.framesPerSecond = framesPerSecond
        self.frameCount = expected
        self.poseBits = poseBits
        self.poseRuns = poseRuns
    }

    func pose(atFrame index: Int) -> TuringGeneratedMouthPose? {
        guard poseBits.indices.contains(index) else { return nil }
        return TuringGeneratedMouthPose(rawValue: poseBits[index])
    }

    func runIndex(containingFrame frameIndex: Int, hint: Int? = nil) -> Int? {
        guard frameIndex >= 0, frameIndex < frameCount else { return nil }
        if let hint, poseRuns.indices.contains(hint),
           poseRuns[hint].contains(frameIndex: frameIndex) { return hint }
        var lower = 0
        var upper = poseRuns.count - 1
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            let run = poseRuns[middle]
            if frameIndex < run.startFrame {
                upper = middle - 1
            } else if frameIndex >= run.endFrameExclusive {
                lower = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }

    static func frameCount(
        sampleCount: Int,
        sampleRate: Int,
        framesPerSecond: Int
    ) throws -> Int {
        guard sampleCount > 0, sampleRate > 0, framesPerSecond > 0 else {
            throw TuringGeneratedSpeechAnalysisError.invalidTimeline
        }
        let product = sampleCount.multipliedReportingOverflow(by: framesPerSecond)
        guard !product.overflow else { throw TuringGeneratedSpeechAnalysisError.timelineOverflow }
        let numerator = product.partialValue.addingReportingOverflow(sampleRate - 1)
        guard !numerator.overflow else { throw TuringGeneratedSpeechAnalysisError.timelineOverflow }
        return numerator.partialValue / sampleRate
    }
}

nonisolated struct TuringGeneratedSpeechVisualAnalysis: Sendable, Equatable {
    let envelope: TuringSpeechAmplitudeEnvelope
    let frameTrack: TuringGeneratedSpeechFrameTrack
}
