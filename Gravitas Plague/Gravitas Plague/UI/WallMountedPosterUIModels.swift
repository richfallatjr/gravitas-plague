import Foundation
import RealityKit
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
    static let maxHeightMeters: Float = 0.6096

    static var aspect: Float {
        sourcePixelSize.x / sourcePixelSize.y
    }

    static var posterHeight: Float {
        maxHeightMeters
    }

    static var posterWidth: Float {
        posterHeight * aspect
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
}
