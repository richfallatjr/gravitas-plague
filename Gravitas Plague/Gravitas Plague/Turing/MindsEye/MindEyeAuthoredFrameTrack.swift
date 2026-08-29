import Foundation

nonisolated enum MindEyeAuthoredMouthLayerBit:
    UInt8,
    Sendable,
    Equatable,
    Hashable,
    CaseIterable
{
    case rest = 1
    case small = 2
    case wide = 4
    case round = 8
    case teeth = 16

    var pose: MindEyeMouthPose {
        switch self {
        case .rest: .rest
        case .small: .small
        case .wide: .wide
        case .round: .round
        case .teeth: .teeth
        }
    }

    init?(pose: MindEyeMouthPose) {
        switch pose {
        case .rest: self = .rest
        case .small: self = .small
        case .wide: self = .wide
        case .round: self = .round
        case .teeth: self = .teeth
        }
    }
}

nonisolated extension MindEyeMouthPose {
    var authoredLayerBit: UInt8 {
        MindEyeAuthoredMouthLayerBit(pose: self)!.rawValue
    }

    init?(authoredLayerBit rawValue: UInt8) {
        guard let bit = MindEyeAuthoredMouthLayerBit(rawValue: rawValue) else {
            return nil
        }
        self = bit.pose
    }
}

nonisolated struct MindEyeAuthoredFrameTrackDescriptor:
    Sendable,
    Equatable,
    Hashable
{
    let prID: String
    let speakerCharacterID: TuringConversationCharacterID
    let interactionSurface: StoryInteractionSurfaceID
    let manifestResourcePath: String
    let manifestSHA256: String
    let descriptorSHA256: String
    let audioSHA256: String
    let transcriptSHA256: String
    let framesSHA256: String
    let sampleRate: Int
    let sampleCount: Int
    let framesPerSecond: Int
    let samplesPerNominalFrame: Int
    let frameCount: Int
    let durationSeconds: Double
}

nonisolated struct MindEyeAuthoredPoseRun:
    Sendable,
    Equatable,
    Hashable
{
    let startFrame: Int
    let endFrameExclusive: Int
    let pose: MindEyeMouthPose

    var frameCount: Int { endFrameExclusive - startFrame }

    func contains(frameIndex: Int) -> Bool {
        startFrame <= frameIndex && frameIndex < endFrameExclusive
    }
}

nonisolated struct MindEyeAuthoredFrameTrack:
    Sendable,
    Equatable
{
    let descriptor: MindEyeAuthoredFrameTrackDescriptor
    private let poseBits: ContiguousArray<UInt8>
    let poseRuns: ContiguousArray<MindEyeAuthoredPoseRun>

    init(
        descriptor: MindEyeAuthoredFrameTrackDescriptor,
        poseBits: ContiguousArray<UInt8>,
        poseRuns: ContiguousArray<MindEyeAuthoredPoseRun>
    ) throws {
        guard poseBits.count == descriptor.frameCount,
              !poseBits.isEmpty,
              !poseRuns.isEmpty else {
            throw Self.failure(descriptor, "Compact authored frame track has inconsistent counts.")
        }
        guard poseBits.allSatisfy({ MindEyeMouthPose(authoredLayerBit: $0) != nil }) else {
            throw Self.failure(descriptor, "Compact authored frame track contains an unknown pose bit.")
        }
        guard poseRuns.first?.startFrame == 0,
              poseRuns.last?.endFrameExclusive == descriptor.frameCount else {
            throw Self.failure(descriptor, "Authored pose runs do not cover the complete track.")
        }

        var previousEnd = 0
        var previousPose: MindEyeMouthPose?
        for run in poseRuns {
            guard run.startFrame == previousEnd,
                  run.endFrameExclusive > run.startFrame,
                  run.endFrameExclusive <= descriptor.frameCount,
                  previousPose != run.pose else {
                throw Self.failure(descriptor, "Authored pose runs are not compact and contiguous.")
            }
            previousEnd = run.endFrameExclusive
            previousPose = run.pose
        }

        self.descriptor = descriptor
        self.poseBits = poseBits
        self.poseRuns = poseRuns
    }

    func pose(atFrame index: Int) -> MindEyeMouthPose? {
        guard poseBits.indices.contains(index) else { return nil }
        return MindEyeMouthPose(authoredLayerBit: poseBits[index])
    }

    func runIndex(containingFrame frameIndex: Int, hint: Int? = nil) -> Int? {
        guard frameIndex >= 0, frameIndex < descriptor.frameCount else { return nil }
        if let hint,
           poseRuns.indices.contains(hint),
           poseRuns[hint].contains(frameIndex: frameIndex) {
            return hint
        }
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

    var compactPoseByteCount: Int { poseBits.count }

    var estimatedCompactByteCount: Int {
        poseBits.count + poseRuns.count * MemoryLayout<MindEyeAuthoredPoseRun>.stride
    }

    private static func failure(
        _ descriptor: MindEyeAuthoredFrameTrackDescriptor,
        _ message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: .authoredFrameTrackInvalid,
            characterID: descriptor.speakerCharacterID,
            vignetteID: nil,
            resourcePath: descriptor.manifestResourcePath,
            message: message
        )
    }
}

nonisolated enum MindEyeAuthoredFrameTrackCompactor {
    static func compact(
        manifest: MindEyeAuthoredFrameManifest,
        indexEntry: MindEyeAuthoredFrameIndex.Entry,
        manifestResourcePath: String,
        manifestSHA256: String
    ) throws -> MindEyeAuthoredFrameTrack {
        var bits = ContiguousArray<UInt8>()
        bits.reserveCapacity(manifest.frames.count)
        var runs = ContiguousArray<MindEyeAuthoredPoseRun>()
        runs.reserveCapacity(max(1, manifest.frames.count / 4))
        var currentPose: MindEyeMouthPose?
        var currentStart = 0

        for frame in manifest.frames {
            guard frame.frameIndex == bits.count,
                  let raw = UInt8(exactly: frame.layerMask),
                  let pose = MindEyeMouthPose(authoredLayerBit: raw),
                  pose == frame.pose else {
                throw MindEyeFailure(
                    code: .authoredFrameManifestInvalid,
                    characterID: manifest.speakerCharacterID,
                    vignetteID: nil,
                    resourcePath: manifestResourcePath,
                    message: "Manifest frame indexes or one-hot pose bits are invalid."
                )
            }
            bits.append(raw)
            if currentPose == nil {
                currentPose = pose
                currentStart = frame.frameIndex
            } else if currentPose != pose {
                runs.append(.init(
                    startFrame: currentStart,
                    endFrameExclusive: frame.frameIndex,
                    pose: currentPose!
                ))
                currentPose = pose
                currentStart = frame.frameIndex
            }
        }
        if let currentPose {
            runs.append(.init(
                startFrame: currentStart,
                endFrameExclusive: manifest.frames.count,
                pose: currentPose
            ))
        }

        let descriptor = MindEyeAuthoredFrameTrackDescriptor(
            prID: manifest.prID,
            speakerCharacterID: manifest.speakerCharacterID,
            interactionSurface: manifest.interactionSurface,
            manifestResourcePath: manifestResourcePath,
            manifestSHA256: manifestSHA256,
            descriptorSHA256: manifest.descriptorSHA256,
            audioSHA256: manifest.audioSHA256,
            transcriptSHA256: manifest.transcriptSHA256,
            framesSHA256: manifest.framesSHA256,
            sampleRate: manifest.timeline.sampleRate,
            sampleCount: manifest.timeline.sampleCount,
            framesPerSecond: manifest.timeline.framesPerSecond,
            samplesPerNominalFrame: manifest.timeline.samplesPerNominalFrame,
            frameCount: manifest.timeline.frameCount,
            durationSeconds: manifest.timeline.durationSeconds
        )
        _ = indexEntry
        return try MindEyeAuthoredFrameTrack(
            descriptor: descriptor,
            poseBits: bits,
            poseRuns: runs
        )
    }
}
