import Foundation

public enum TuringQwenNativeGPUAdmissionMode:
    String,
    Codable,
    Sendable,
    Equatable,
    CaseIterable
{
    /// Existing Fresh2 behavior. Generation and serialized decode may overlap.
    case currentOverlap

    /// Phase 1 candidate. Two generation stages may overlap, but decode and
    /// generation are mutually exclusive.
    case decodeExclusive
}

public struct TuringQwenNativeGPUAdmissionPolicy: Sendable, Equatable {
    public let mode: TuringQwenNativeGPUAdmissionMode
    public let maximumConcurrentGenerationLeases: Int
    public let decoderHasPriority: Bool

    public init(
        mode: TuringQwenNativeGPUAdmissionMode,
        maximumConcurrentGenerationLeases: Int = 2,
        decoderHasPriority: Bool = true
    ) throws {
        guard maximumConcurrentGenerationLeases == 2 else {
            throw TuringQwenNativeError.invalidConfig(
                "Phase 1 must preserve exactly two generation permits."
            )
        }
        guard decoderHasPriority else {
            throw TuringQwenNativeError.invalidConfig(
                "Phase 1 decode-exclusive mode requires decoder priority to avoid starvation."
            )
        }

        self.mode = mode
        self.maximumConcurrentGenerationLeases =
            maximumConcurrentGenerationLeases
        self.decoderHasPriority = decoderHasPriority
    }

    public static var currentProduction: Self {
        get throws {
            try Self(mode: .currentOverlap)
        }
    }

    public static var phase1Candidate: Self {
        get throws {
            try Self(mode: .decodeExclusive)
        }
    }
}

public enum TuringQwenNativeGPUWorkKind: String, Sendable, Equatable {
    case generation
    case speechDecode
}

public struct TuringQwenNativeGPUWorkIdentity:
    Sendable,
    Equatable,
    Hashable
{
    public let runID: String
    public let segmentIndex: Int
    public let laneIndex: Int?
    public let instanceID: String?
    public let decodeID: Int?

    public init(
        runID: String,
        segmentIndex: Int,
        laneIndex: Int?,
        instanceID: String?,
        decodeID: Int?
    ) {
        self.runID = runID
        self.segmentIndex = segmentIndex
        self.laneIndex = laneIndex
        self.instanceID = instanceID
        self.decodeID = decodeID
    }
}

public struct TuringQwenNativeGPUAdmissionLease:
    Sendable,
    Equatable,
    Hashable
{
    public let id: UUID
    public let kind: TuringQwenNativeGPUWorkKind
    public let work: TuringQwenNativeGPUWorkIdentity

    let isNoOp: Bool
}
