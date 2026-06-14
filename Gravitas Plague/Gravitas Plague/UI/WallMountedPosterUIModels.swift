import Foundation
import RealityKit
import UIKit
import simd

enum WallPosterAction: String, Codable {
    case horde
    case walkLoop
}

struct WallPosterUIButtonComponent: Component, Codable {
    let actionRawValue: String

    var action: WallPosterAction? {
        WallPosterAction(
            rawValue: actionRawValue
        )
    }
}

struct WallPosterKillSwitchComponent: Component, Codable {
    let id: String
}

struct WallPosterLeaderboardButtonComponent: Component, Codable {
    let id: String
}

enum WallStickerStyle {
    static let twoStopsDownTint = UIColor(
        white: 0.25,
        alpha: 0.92
    )

    static let stickerSizeMeters: Float = 0.085
    static let stickerSpacingMeters: Float = 0.035
}

struct WallPosterPlacement {
    var wallID: UUID
    var localX: Float
    var localY: Float
    var depthOffset: Float
    var width: Float
    var height: Float
}

enum WallPosterMetrics {
    static let sourcePixelSize = SIMD2<Float>(
        1086,
        1448
    )
    static let minimumHeightMeters: Float = 4.0 * 0.3048
    static let maxHeightMeters: Float = minimumHeightMeters
    static let portalHardClearancePaddingMeters: Float = 2.0 * 0.3048
    static let placementRejectionPaddingMeters: Float = 2.0 * 0.3048
    static let wallMarginMeters: Float = 0.12

    static var aspect: Float {
        sourcePixelSize.x / sourcePixelSize.y
    }

    static let depthOffset: Float = 0.018

    static let hordeRectPixels = SIMD4<Float>(
        52,
        1101,
        490,
        141
    )

    static let walkRectPixels = SIMD4<Float>(
        557,
        1100,
        478,
        143
    )

    static func posterSize(
        for wall: WallCandidate
    ) -> SIMD2<Float> {
        let availableHeight = max(
            minimumHeightMeters,
            wall.height - wallMarginMeters * 2.0
        )
        let height = max(
            minimumHeightMeters,
            min(
                maxHeightMeters,
                availableHeight
            )
        )
        var width = height * aspect
        let maxWidth = max(
            minimumHeightMeters * aspect,
            wall.width - wallMarginMeters * 2.0
        )

        if width > maxWidth {
            width = maxWidth
            return SIMD2<Float>(
                width,
                max(
                    minimumHeightMeters,
                    width / aspect
                )
            )
        }

        return SIMD2<Float>(
            width,
            height
        )
    }
}
