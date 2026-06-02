import Foundation

struct JockRuntimeLocomotionDelta: Equatable {
    let clipID: String
    let time: TimeInterval
    let didWrap: Bool

    /// Positive means authored forward travel.
    let forwardMeters: Float

    /// Positive means authored local right.
    let sideMeters: Float

    /// Positive means authored vertical up.
    let verticalMeters: Float

    /// Positive or negative authored yaw delta.
    let yawDegrees: Float

    nonisolated static let zero = JockRuntimeLocomotionDelta(
        clipID: "",
        time: 0,
        didWrap: false,
        forwardMeters: 0,
        sideMeters: 0,
        verticalMeters: 0,
        yawDegrees: 0
    )
}
