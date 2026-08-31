import Foundation

nonisolated enum MindEyeProjectionError: LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidProfileID(String)
    case invalidSubjectAsset
    case invalidSquarePixelBudget
    case invalidMaterialControls
    case invalidViewCone
    case invalidMaskControls
    case invalidReceiverMask(String)
    case unsupportedImportedPBR(String)
    case materialParityUnqualified
    case materialContractMismatch(String)
    case stalePreparation
    case coordinateSpaceProofFailed(String)
    case invalidCameraDescriptor
    case nonfiniteCameraDescriptor
    case invalidTargetDescriptor(String)
    case invalidPlateManifest(String)
    case missingResource(String)
    case hashMismatch(String)
    case targetResolutionFailed(String)
    case materialApplicationFailed(String)
    case rendererUnavailable(String)
    case renderTimedOut
    case renderFailed(String)
    case invalidCapture(String)
    case invalidAuthoringJob(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let value): "Unsupported projection schema version: \(value)."
        case .invalidProfileID(let value): "Invalid projection profile ID: \(value)."
        case .invalidSubjectAsset: "The projection subject asset is invalid."
        case .invalidSquarePixelBudget: "The square projection pixel budget is invalid."
        case .invalidMaterialControls: "Projection material controls are invalid."
        case .invalidViewCone: "Projection view-cone controls are invalid."
        case .invalidMaskControls: "Projection mask controls are invalid."
        case .invalidReceiverMask(let message): "Invalid projection receiver mask: \(message)"
        case .unsupportedImportedPBR(let message): "Unsupported imported Angel PBR contract: \(message)"
        case .materialParityUnqualified: "The Angel replacement material has not passed parity qualification."
        case .materialContractMismatch(let message): "Angel material contract mismatch: \(message)"
        case .stalePreparation: "The Angel projection material preparation became stale."
        case .coordinateSpaceProofFailed(let message): "Projection coordinate-space proof failed: \(message)"
        case .invalidCameraDescriptor: "The projection camera descriptor is invalid."
        case .nonfiniteCameraDescriptor: "The projection camera contains a non-finite value."
        case .invalidTargetDescriptor(let message): "Invalid projection target: \(message)"
        case .invalidPlateManifest(let message): "Invalid projection plate package: \(message)"
        case .missingResource(let path): "Missing projection resource: \(path)"
        case .hashMismatch(let role): "Projection resource hash mismatch: \(role)"
        case .targetResolutionFailed(let message): "Projection target resolution failed: \(message)"
        case .materialApplicationFailed(let message): "Projection material application failed: \(message)"
        case .rendererUnavailable(let message): "RealityRenderer is unavailable: \(message)"
        case .renderTimedOut: "Projection authoring render exceeded its ten-second watchdog."
        case .renderFailed(let message): "Projection render failed: \(message)"
        case .invalidCapture(let message): "Invalid projection capture: \(message)"
        case .invalidAuthoringJob(let value): "Invalid projection authoring job: \(value)"
        }
    }
}
