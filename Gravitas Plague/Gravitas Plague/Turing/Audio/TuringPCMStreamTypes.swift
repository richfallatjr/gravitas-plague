import Foundation

nonisolated enum TuringPCMStreamError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case staleHandle
    case appendAfterSeal
    case appendAlreadyInProgress
    case sequenceMismatch(expected: Int, actual: Int)
    case frameOffsetMismatch(expected: Int, actual: Int)
    case invalidChunk(String)
    case chunkExceedsCapacity(frameCount: Int, capacityFrames: Int)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid PCM stream configuration: \(message)"
        case .staleHandle:
            return "PCM stream handle is stale."
        case .appendAfterSeal:
            return "PCM stream is already sealed."
        case .appendAlreadyInProgress:
            return "PCM stream already has an append in progress."
        case .sequenceMismatch(let expected, let actual):
            return "PCM chunk sequence mismatch: expected \(expected), received \(actual)."
        case .frameOffsetMismatch(let expected, let actual):
            return "PCM chunk frame offset mismatch: expected \(expected), received \(actual)."
        case .invalidChunk(let message):
            return "Invalid PCM stream chunk: \(message)"
        case .chunkExceedsCapacity(let frameCount, let capacityFrames):
            return "PCM chunk has \(frameCount) output frames, exceeding the \(capacityFrames)-frame stream capacity."
        case .conversionFailed(let message):
            return "PCM stream sample-rate conversion failed: \(message)"
        }
    }
}

nonisolated struct TuringPCMStreamConfiguration: Sendable, Equatable {
    static let realityKitSampleRate = 48_000
    static let qwenDefault = TuringPCMStreamConfiguration(
        sourceSampleRate: 24_000,
        channelCount: 1,
        capacitySeconds: 8,
        startupWatermarkSeconds: 0.75
    )

    let sourceSampleRate: Int
    let channelCount: Int
    let capacitySeconds: Double
    let startupWatermarkSeconds: Double

    init(
        sourceSampleRate: Int = 24_000,
        channelCount: Int = 1,
        capacitySeconds: Double = 8,
        startupWatermarkSeconds: Double = 0.75
    ) {
        self.sourceSampleRate = sourceSampleRate
        self.channelCount = channelCount
        self.capacitySeconds = capacitySeconds
        self.startupWatermarkSeconds = startupWatermarkSeconds
    }

    var outputCapacityFrames: Int {
        Int(
            ceil(
                capacitySeconds *
                    Double(Self.realityKitSampleRate)
            )
        )
    }

    var startupWatermarkFrames: Int {
        Int(
            ceil(
                startupWatermarkSeconds *
                    Double(Self.realityKitSampleRate)
            )
        )
    }

    func validate() throws {
        guard sourceSampleRate > 0 else {
            throw TuringPCMStreamError.invalidConfiguration(
                "sourceSampleRate must be positive."
            )
        }
        guard channelCount == 1 else {
            throw TuringPCMStreamError.invalidConfiguration(
                "RealityKit generated speech currently requires mono PCM."
            )
        }
        guard capacitySeconds.isFinite,
              capacitySeconds > 0 else {
            throw TuringPCMStreamError.invalidConfiguration(
                "capacitySeconds must be finite and positive."
            )
        }
        guard startupWatermarkSeconds.isFinite,
              startupWatermarkSeconds > 0,
              startupWatermarkSeconds <= capacitySeconds else {
            throw TuringPCMStreamError.invalidConfiguration(
                "startupWatermarkSeconds must be finite, positive, and no greater than capacitySeconds."
            )
        }
        guard outputCapacityFrames > 0,
              startupWatermarkFrames > 0 else {
            throw TuringPCMStreamError.invalidConfiguration(
                "capacity and startup watermark must contain at least one output frame."
            )
        }
    }
}

nonisolated struct TuringPCMStreamRequest: Sendable, Equatable {
    let requestID: UUID
    let runID: String
    let kind: TuringAudioClipKind
    let route: TuringAudioRouteID
    let label: String
    let gainDB: Float
    let configuration: TuringPCMStreamConfiguration

    init(
        requestID: UUID = UUID(),
        runID: String,
        kind: TuringAudioClipKind = .generated,
        route: TuringAudioRouteID,
        label: String,
        gainDB: Float,
        configuration: TuringPCMStreamConfiguration = .qwenDefault
    ) {
        self.requestID = requestID
        self.runID = runID
        self.kind = kind
        self.route = route
        self.label = label
        self.gainDB = gainDB
        self.configuration = configuration
    }
}

nonisolated struct TuringPCMStreamChunk: Sendable, Equatable {
    let sequenceNumber: Int
    let sourceFrameOffset: Int
    let samples: [Float]
    let sampleRate: Int
    let channelCount: Int

    init(
        sequenceNumber: Int,
        sourceFrameOffset: Int,
        samples: [Float],
        sampleRate: Int = 24_000,
        channelCount: Int = 1
    ) {
        self.sequenceNumber = sequenceNumber
        self.sourceFrameOffset = sourceFrameOffset
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    var sourceFrameCount: Int {
        guard channelCount > 0 else { return 0 }
        return samples.count / channelCount
    }
}

nonisolated struct TuringPCMStreamAppendReceipt: Sendable, Equatable {
    let acceptedSequenceNumber: Int
    let acceptedSourceFrameOffset: Int
    let acceptedSourceFrameCount: Int
    let convertedOutputFrameCount: Int
    let bufferedSeconds: Double
    let playbackStartRequested: Bool
}

nonisolated struct TuringPCMStreamMetrics: Sendable, Equatable {
    let capacitySeconds: Double
    let startupWatermarkSeconds: Double
    let bufferedSeconds: Double
    let appendedSourceFrames: Int
    let convertedOutputFrames: Int
    let renderedOutputFrames: Int
    let underrunCount: Int
    let underrunFrames: Int
    let nextExpectedSequenceNumber: Int
    let nextExpectedSourceFrameOffset: Int
    let isSealed: Bool
    let isDrained: Bool
    let hasRenderedPCM: Bool
}

nonisolated protocol TuringPCMStreamingPlaybackEndpoint:
    TuringAudioPlaybackEndpoint
{
    func openPCMStream(
        _ request: TuringPCMStreamRequest
    ) async throws -> TuringAudioPlaybackHandle

    func appendPCMStream(
        _ chunk: TuringPCMStreamChunk,
        to handle: TuringAudioPlaybackHandle
    ) async throws -> TuringPCMStreamAppendReceipt

    func sealPCMStream(
        _ handle: TuringAudioPlaybackHandle
    ) async throws

    func pcmStreamMetrics(
        _ handle: TuringAudioPlaybackHandle
    ) async -> TuringPCMStreamMetrics?
}
