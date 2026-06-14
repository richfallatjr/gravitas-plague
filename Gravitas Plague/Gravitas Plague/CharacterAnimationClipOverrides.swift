import Foundation

enum JockAnimationRole: String, Codable, CaseIterable {
    case idle
    case walk
    case attack
    case hitReact
    case death
    case turn
    case unknown
}

enum CharacterAnimationClipOverrides {
    static func overrideClipID(
        archetype: PlagueCharacterArchetype,
        role: JockAnimationRole
    ) -> String? {
        nil
    }
}

enum RequiredCharacterAnimationClips {
    static let requiredClipIDs: [String] = []

    static func validate(
        availableClipIDs: Set<String>
    ) {
        for clipID in requiredClipIDs {
            if availableClipIDs.contains(clipID) {
                print("[CharacterAnimationClipResolver] found required clip \(clipID)")
            } else {
                print("[CharacterAnimationClipResolver] ERROR missing required clip \(clipID)")
            }
        }
    }
}
