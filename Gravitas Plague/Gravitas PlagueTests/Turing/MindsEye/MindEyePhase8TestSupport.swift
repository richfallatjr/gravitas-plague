import Foundation

@testable import Gravitas_Plague

enum MindEyePhase8TestFixtures {
    static func track(
        poses: [MindEyeMouthPose] = [.rest, .small, .small, .teeth, .wide, .round]
    ) throws -> MindEyeAuthoredFrameTrack {
        let bits = ContiguousArray(poses.map(\.authoredLayerBit))
        var runs = ContiguousArray<MindEyeAuthoredPoseRun>()
        var start = 0
        for index in poses.indices where index == 0 || poses[index] != poses[index - 1] {
            if index > 0 {
                runs.append(.init(
                    startFrame: start,
                    endFrameExclusive: index,
                    pose: poses[start]
                ))
            }
            start = index
        }
        runs.append(.init(
            startFrame: start,
            endFrameExclusive: poses.count,
            pose: poses[start]
        ))
        return try MindEyeAuthoredFrameTrack(
            descriptor: .init(
                prID: "phase8.test.pr",
                speakerCharacterID: .bigMike,
                interactionSurface: .walkie,
                manifestResourcePath: "Turing/MindsEye/AudioFrames/phase8.test.pr.mouthframes.json",
                manifestSHA256: String(repeating: "1", count: 64),
                descriptorSHA256: String(repeating: "2", count: 64),
                audioSHA256: String(repeating: "3", count: 64),
                transcriptSHA256: String(repeating: "4", count: 64),
                framesSHA256: String(repeating: "5", count: 64),
                sampleRate: 48_000,
                sampleCount: poses.count * 800,
                framesPerSecond: 60,
                samplesPerNominalFrame: 800,
                frameCount: poses.count,
                durationSeconds: Double(poses.count) / 60
            ),
            poseBits: bits,
            poseRuns: runs
        )
    }

    static var key: MindEyePresentationKey {
        .init(
            playbackRunID: "phase8-run",
            playbackHandleID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
    }

    static var sourceResourceRoot: URL {
        mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/TuringResources",
            isDirectory: true
        )
    }
}
