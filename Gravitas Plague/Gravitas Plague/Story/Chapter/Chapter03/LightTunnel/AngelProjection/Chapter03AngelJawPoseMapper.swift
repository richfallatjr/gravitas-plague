import Foundation

nonisolated enum Chapter03AngelJawPoseMapper {
    static let rest: Float = 0.00
    static let teeth: Float = 0.00
    static let small: Float = 0.33
    static let round: Float = 0.50
    static let wide: Float = 1.00

    static func weight(for pose: MindEyeMouthPose) -> Float {
        switch pose {
        case .rest:
            rest
        case .teeth:
            teeth
        case .small:
            small
        case .round:
            round
        case .wide:
            wide
        }
    }

    static let orderedMapping: [MindEyeMouthPose: Float] = [
        .rest: rest,
        .small: small,
        .wide: wide,
        .round: round,
        .teeth: teeth,
    ]
}
