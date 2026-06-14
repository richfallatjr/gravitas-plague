import simd
import UIKit

enum PortalGlyphFXSettings {
    static let pixelsPerMeter: Float = 1024.0

    static let wallDepthOffset: Float = 0.024
    static let floorLift: Float = 0.006

    static let glyphCountPerSegmentRange = 5...10
    static let directionalPreference: Float = 0.68

    static let wallGlyphPadding: Float = 0.018
    static let floorGlyphPadding: Float = 0.025

    static let directionalLaneSpacing: Float = 0.075
    static let directionalMaxLanes = 4

    static let freeGlyphScatterRadius: Float = 0.38

    static let floorGlyphCountRange = 3...7
    static let floorForwardMin: Float = 0.15
    static let floorForwardMax: Float = 1.15
    static let floorSideSpread: Float = 0.65

    static let emissiveTint = UIColor(
        red: 1.0,
        green: 0.22,
        blue: 0.035,
        alpha: 1.0
    )

    static let baseTint = UIColor(
        red: 0.95,
        green: 0.10,
        blue: 0.02,
        alpha: 1.0
    )

    static let emissiveIntensity: Float = 3.0
}
