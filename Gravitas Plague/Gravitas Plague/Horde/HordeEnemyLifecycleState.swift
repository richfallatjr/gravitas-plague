enum HordeEnemyLifecycleState: String {
    case portalIngress
    case active
    case dying
    case corpse
    case cleanedUp

    var isLivingGameplayEnemy: Bool {
        switch self {
        case .portalIngress, .active:
            return true
        case .dying, .corpse, .cleanedUp:
            return false
        }
    }

    var canRunLocomotion: Bool {
        switch self {
        case .portalIngress, .active:
            return true
        case .dying, .corpse, .cleanedUp:
            return false
        }
    }

    var canPlayWalkOrFollow: Bool {
        switch self {
        case .portalIngress, .active:
            return true
        case .dying, .corpse, .cleanedUp:
            return false
        }
    }
}
