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
    static let robotWalkClipID = "robot_walk_01"

    static func overrideClipID(
        archetype: PlagueCharacterArchetype,
        role: JockAnimationRole
    ) -> String? {
        switch (archetype, role) {
        case (.robot, .walk):
            return robotWalkClipID

        default:
            return nil
        }
    }
}

enum RequiredCharacterAnimationClips {
    static let requiredClipIDs: [String] = [
        CharacterAnimationClipOverrides.robotWalkClipID
    ]

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
