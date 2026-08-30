import Foundation

nonisolated struct Chapter03AngelVisemeTrack: Sendable, Equatable {
    struct Run: Sendable, Equatable {
        let startFrame: Int
        let endFrameExclusive: Int
        let pose: MindEyeMouthPose
    }

    let trackID: String
    let sampleRate: Int
    let sampleCount: Int
    let framesPerSecond: Int
    let frameCount: Int
    let runs: ContiguousArray<Run>

    func pose(atFrame frame: Int, cursor: inout Int) -> MindEyeMouthPose {
        guard frame >= 0, frame < frameCount, !runs.isEmpty else { return .rest }
        if runs.indices.contains(cursor) {
            let current = runs[cursor]
            if frame >= current.startFrame, frame < current.endFrameExclusive {
                return current.pose
            }
            if frame >= current.endFrameExclusive {
                while cursor + 1 < runs.count,
                      frame >= runs[cursor].endFrameExclusive {
                    cursor += 1
                }
                let advanced = runs[cursor]
                if frame >= advanced.startFrame, frame < advanced.endFrameExclusive {
                    return advanced.pose
                }
            }
        }
        cursor = binarySearchRun(containing: frame) ?? 0
        let run = runs[cursor]
        return frame >= run.startFrame && frame < run.endFrameExclusive
            ? run.pose
            : .rest
    }

    private func binarySearchRun(containing frame: Int) -> Int? {
        var low = 0
        var high = runs.count - 1
        while low <= high {
            let middle = low + (high - low) / 2
            let run = runs[middle]
            if frame < run.startFrame {
                high = middle - 1
            } else if frame >= run.endFrameExclusive {
                low = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }
}
