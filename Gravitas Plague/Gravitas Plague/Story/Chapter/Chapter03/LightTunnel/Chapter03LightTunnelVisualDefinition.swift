import Foundation

nonisolated struct Chapter03LightTunnelVisualDefinition: Codable, Sendable, Equatable {
    let portalDiameterMeters: Float
    let startDistanceMeters: Float
    let endDistanceMeters: Float
    let approachDurationSeconds: Double
    let angelInsideOffsetMeters: Float
    let angelRootYOffsetMeters: Float
    let domeRadiusMeters: Float
    let domeCenterOffsetZMeters: Float

    nonisolated func validate() throws {
        guard portalDiameterMeters.isFinite,
              (2.13...2.44).contains(portalDiameterMeters),
              startDistanceMeters.isFinite,
              abs(startDistanceMeters - 30.48) < 0.01,
              endDistanceMeters.isFinite,
              abs(endDistanceMeters - 3.048) < 0.01,
              startDistanceMeters > endDistanceMeters,
              approachDurationSeconds == 60,
              angelInsideOffsetMeters.isFinite,
              angelInsideOffsetMeters >= 0.75,
              angelInsideOffsetMeters <= 1.25,
              angelRootYOffsetMeters.isFinite,
              angelRootYOffsetMeters >= -1.2,
              angelRootYOffsetMeters <= -0.6,
              domeRadiusMeters >= 10,
              domeCenterOffsetZMeters <= -6 else {
            throw Chapter03Error.definitionInvalid("visual limits are invalid")
        }
    }
}
