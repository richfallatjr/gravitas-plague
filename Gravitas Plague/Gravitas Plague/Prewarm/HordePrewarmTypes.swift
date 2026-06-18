import Foundation
import RealityKit

enum HordePrewarmState: String, Sendable {
    case notRequested
    case loading
    case ready
    case failed
}

struct HordeCharacterPrewarmStatus: Sendable {
    let characterID: String
    let state: HordePrewarmState
    let sourceAssetName: String
    let readyCloneCount: Int
    let requiredCloneCount: Int
    let errorDescription: String?
}

struct HordeAnimationPrewarmStatus: Sendable {
    let clipID: String
    let state: HordePrewarmState
    let errorDescription: String?
}

enum HordePrewarmError: Error, LocalizedError {
    case missingCharacterAsset(characterID: String, file: String)
    case characterNotReady(characterID: String)
    case missingAnimationClip(clipID: String)
    case animationPrewarmFailed(clipID: String, reason: String)
    case spawnPoseInvalid(characterID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingCharacterAsset(let characterID, let file):
            return "Missing character asset for \(characterID): \(file)"
        case .characterNotReady(let characterID):
            return "Character is not prewarmed: \(characterID)"
        case .missingAnimationClip(let clipID):
            return "Missing animation clip: \(clipID)"
        case .animationPrewarmFailed(let clipID, let reason):
            return "Animation prewarm failed for \(clipID): \(reason)"
        case .spawnPoseInvalid(let characterID, let reason):
            return "Spawn pose is invalid for \(characterID): \(reason)"
        }
    }
}

struct HordePrewarmedAnimationLibrary: @unchecked Sendable {
    let rigDefinition: JockRigDefinition
    let skeletonMap: JockSkeletonMap
    let manifest: JockAnimationManifest
    let runtimeOverrides: JockRuntimeClipOverrides
    let clipsByID: [String: JockAnimClip]
    let sourceRigEntriesByID: [String: JockSourceRigEntry]
}

struct HordePrewarmedCharacterSpawnAssets {
    let characterEntity: Entity
}
