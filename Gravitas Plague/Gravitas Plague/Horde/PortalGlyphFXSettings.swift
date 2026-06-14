import simd
import UIKit

enum PortalGlyphFXSettings {
    static let pixelsPerFoot: Float = 1024.0
    static let feetToMeters: Float = 0.3048

    static let wallDepthOffset: Float = 0.024
    static let floorLift: Float = 0.006

    static let wallGlyphPadding: Float = 0.0
    static let floorGlyphPadding: Float = 0.0

    /// Desired max spread. Try this first.
    static let targetMaxDistanceFromBorderFeet: Float = 2.0
    static let targetMaxDistanceFromBorderMeters: Float =
        targetMaxDistanceFromBorderFeet * feetToMeters

    /// Soft fallback only for failed strict placement.
    static let fallbackMaxDistanceFromBorderFeet: Float = 2.65
    static let fallbackMaxDistanceFromBorderMeters: Float =
        fallbackMaxDistanceFromBorderFeet * feetToMeters

    /// General glyphs may be on-border or outside; strict pass targets 2ft.
    static let generalBorderProbability: Float = 0.48

    static let candidateAttemptsPerGlyph = 128
    static let fallbackCandidateAttemptsPerGlyph = 64

    /// Hard total cap per non-bottom portal line.
    static let maxWallGlyphsPerSegment = 3

    /// Try to put at least this many on each non-bottom line.
    static let minWallGlyphsPerSegmentWhenPossible = 1

    /// Exactly one floor glyph per portal.
    static let floorGlyphCountPerPortal = 1

    /// Entire portal limit.
    static let maxCircleGlyphsPerPortal = 1

    /// Chance that a portal gets its one circle glyph when circle assets exist.
    static let circleGlyphProbability: Float = 0.85

    static let directionalPreference: Float = 0.58

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
