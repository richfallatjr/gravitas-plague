import Foundation

struct JockFollowDemoConfiguration: Equatable {
    let idleClipID: String
    let walkClipID: String

    let stopDistanceMeters: Float
    let resumeDistanceMeters: Float

    let maxTurnDegreesPerSecond: Float
    let facingDeadZoneDegrees: Float

    let walkDistanceScale: Float

    /// Use 1.0 if positive authored forward moves toward root forward.
    /// Use -1.0 if the donor/exported locomotion is inverted.
    let followForwardSign: Float

    let maxStepMetersPerFrame: Float

    let idleBeforeFollowDelay: TimeInterval

    nonisolated static let defaultDemo = JockFollowDemoConfiguration(
        idleClipID: "idle_01",
        walkClipID: "unstable_walk_01",

        stopDistanceMeters: 1.35,
        resumeDistanceMeters: 1.75,

        maxTurnDegreesPerSecond: 55.0,
        facingDeadZoneDegrees: 4.0,

        walkDistanceScale: 1.0,
        followForwardSign: -1.0,
        maxStepMetersPerFrame: 0.06,

        idleBeforeFollowDelay: 0.35
    )

    var maxTurnRadiansPerSecond: Float {
        maxTurnDegreesPerSecond * Float.pi / 180.0
    }

    var facingDeadZoneRadians: Float {
        facingDeadZoneDegrees * Float.pi / 180.0
    }
}
