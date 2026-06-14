import simd
import UIKit

enum PortalGlyphFXSettings {
    static let pixelsPerFoot: Float = 1024.0
    static let feetToMeters: Float = 0.3048

    static let wallDepthOffset: Float = 0.024
    static let floorLift: Float = 0.006

    static let wallGlyphPadding: Float = 0.0
    static let floorGlyphPadding: Float = 0.0

    /// Absolute maximum spread from nearest non-bottom portal border.
    static let maxDistanceFromBorderFeet: Float = 3.0
    static let maxDistanceFromBorderMeters: Float =
        maxDistanceFromBorderFeet * feetToMeters

    /// Directional glyphs sit directly against the border.
    static let directionalBorderJitterMeters: Float = 0.015

    /// General glyphs may be on-border or outside, but never farther than 3ft.
    static let generalBorderProbability: Float = 0.42

    static let wallGlyphCountPerSegmentRange = 5...12

    /// Exactly one floor glyph per portal.
    static let floorGlyphCountPerPortal = 1

    static let candidateAttemptsPerGlyph = 128

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
        alpha: 0.92
    )

    static let emissiveIntensity: Float = 3.0
}
