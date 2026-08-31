import Foundation
import simd

nonisolated struct MindEyeProjectorUV: Sendable, Equatable {
    let value: SIMD2<Float>
}

nonisolated struct MindEyeModelUV: Sendable, Equatable {
    let value: SIMD2<Float>
    let setName: String
    let setIndex: Int
}

nonisolated enum MindEyeProjectionMaterialDiagnosticMode: String, Sendable, Equatable, Hashable {
    case production
    case originalImportedPBR
    case projectionMaterialCoverageZero
    case visualizeReceiverUVMask
    case visualizeProjectorChecker

    var projectionEnabled: Float {
        switch self {
        case .production, .visualizeProjectorChecker: 1
        case .originalImportedPBR, .projectionMaterialCoverageZero,
             .visualizeReceiverUVMask: 0
        }
    }
}

@MainActor
final class MindEyeProjectionPreparationToken {
    let ID = UUID()
    private(set) var isCurrent = true

    func cancel() { isCurrent = false }

    func requireCurrent() throws {
        if Task.isCancelled { throw CancellationError() }
        guard isCurrent else { throw MindEyeProjectionError.stalePreparation }
    }
}

#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
nonisolated struct MindEyeProjectionCoordinateProofReport: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let graphVersion: String
    let cameraSHA256: String
    let receiverMaskSHA256: String
    let receiverUVSetName: String
    let receiverUVSetIndex: Int
    let weights: [Float]
    let checkerFrameSHA256: [String]
    let blendshapeChangesProjectedSurface: Bool
    let projectorMotionChangesChecker: Bool
    let projectorMotionChangesUVBoundary: Bool?
    let UVMaskChangeReframesChecker: Bool?
    let physicalDeviceQualified: Bool
    let qualificationNote: String
}
#endif
