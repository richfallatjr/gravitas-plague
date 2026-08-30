import Foundation

nonisolated enum MindEyeProjectionError: LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidProfileID(String)
    case invalidSubjectAsset
    case invalidSquarePixelBudget
    case invalidMaterialControls
    case invalidViewCone
    case invalidMaskControls
    case invalidCameraDescriptor
    case nonfiniteCameraDescriptor
    case invalidTargetDescriptor(String)
    case missingResource(String)
    case hashMismatch(String)
    case targetResolutionFailed(String)
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
        case .invalidCameraDescriptor: "The projection camera descriptor is invalid."
        case .nonfiniteCameraDescriptor: "The projection camera contains a non-finite value."
        case .invalidTargetDescriptor(let message): "Invalid projection target: \(message)"
        case .missingResource(let path): "Missing projection resource: \(path)"
        case .hashMismatch(let role): "Projection resource hash mismatch: \(role)"
        case .targetResolutionFailed(let message): "Projection target resolution failed: \(message)"
        case .rendererUnavailable(let message): "RealityRenderer is unavailable: \(message)"
        case .renderTimedOut: "Projection authoring render exceeded its ten-second watchdog."
        case .renderFailed(let message): "Projection render failed: \(message)"
        case .invalidCapture(let message): "Invalid projection capture: \(message)"
        case .invalidAuthoringJob(let value): "Invalid projection authoring job: \(value)"
        }
    }
}
