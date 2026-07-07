import Foundation
import simd

struct TuringStoryWallBundlePlacement: Codable, Equatable, Sendable {
    var wallID: UUID
    var localX: Float
    var localY: Float
    var depthOffset: Float
    var width: Float
    var height: Float
    var floorWorldY: Float?
}

enum TuringStoryWalkieBundleTuning {
    static let feetToMeters: Float = 0.3048
    static let assetImportScale: Float = 3.0
    static let preferredCenterHeightMeters: Float = 4.0 * feetToMeters
    static let minBottomClearanceMeters: Float = 0.60
    static let wallMarginMeters: Float = 0.10
    static let depthOffset: Float = 0.025
    static let defaultWidthMeters: Float = 0.65
    static let defaultHeightMeters: Float = 0.45
    static let occupancyPaddingMeters: Float = 0.12
    static let posterAvoidanceWeight: Float = 5.0
    static let portalAvoidanceWeight: Float = 4.0
}

func turingWalkieWallRect(
    for placement: TuringStoryWallBundlePlacement
) -> WallLocalRect {
    WallLocalRect(
        minX: placement.localX - placement.width * 0.5,
        minY: placement.localY - placement.height * 0.5,
        maxX: placement.localX + placement.width * 0.5,
        maxY: placement.localY + placement.height * 0.5
    )
}
