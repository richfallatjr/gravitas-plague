import Foundation

nonisolated enum PortalFXVisemeDensityMapper {
    static let rest: Float = 1.00
    static let small: Float = 1.33
    static let round: Float = 1.50
    static let teeth: Float = 1.75
    static let wide: Float = 2.00

    nonisolated static func multiplier(
        for pose: MindEyeMouthPose
    ) -> Float {
        switch pose {
        case .rest:
            rest
        case .small:
            small
        case .round:
            round
        case .teeth:
            teeth
        case .wide:
            wide
        }
    }

    nonisolated static func effectiveBirthRate(for pose: MindEyeMouthPose) -> Float {
        PortalFXDefaults.emberBirthRatePerDoor * multiplier(for: pose)
    }

    static let orderedMapping: [MindEyeMouthPose: Float] = [
        .rest: rest,
        .small: small,
        .round: round,
        .teeth: teeth,
        .wide: wide,
    ]
}
