import Combine
import CoreGraphics
import Foundation
import simd

struct PosterNormalizedRect: Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct PosterModeRegion: Sendable, Identifiable {
    let mode: PlagueDemoSession.PlagueOperationMode
    let sourcePixelRect: CGRect
    let normalizedRect: PosterNormalizedRect

    var id: PlagueDemoSession.PlagueOperationMode {
        mode
    }
}

enum OperationModePosterLayout {
    static let assetName = "user-interface"
    static let assetExtension = "png"

    static let referencePixelWidth: Double = 1055
    static let referencePixelHeight: Double = 1505

    static let referencePixelSize = CGSize(
        width: referencePixelWidth,
        height: referencePixelHeight
    )

    static let storySourceRect = CGRect(
        x: 44,
        y: 1167,
        width: 481,
        height: 133
    )

    static let hordeSourceRect = CGRect(
        x: 538,
        y: 1168,
        width: 479,
        height: 132
    )

    static let storyRegion = PosterModeRegion(
        mode: .story,
        sourcePixelRect: storySourceRect,
        normalizedRect: normalized(storySourceRect)
    )

    static let hordeRegion = PosterModeRegion(
        mode: .horde,
        sourcePixelRect: hordeSourceRect,
        normalizedRect: normalized(hordeSourceRect)
    )

    static let regions = [
        storyRegion,
        hordeRegion
    ]

    static func region(
        for mode: PlagueDemoSession.PlagueOperationMode
    ) -> PosterModeRegion? {
        switch mode {
        case .story:
            return storyRegion

        case .horde:
            return hordeRegion

        case .walkLoop:
            return nil
        }
    }

    private static func normalized(
        _ rect: CGRect
    ) -> PosterNormalizedRect {
        PosterNormalizedRect(
            x: rect.minX / referencePixelWidth,
            y: rect.minY / referencePixelHeight,
            width: rect.width / referencePixelWidth,
            height: rect.height / referencePixelHeight
        )
    }
}

enum PosterCoordinateMapper {
    static func aspectFitImageRect(
        sourceSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let sourceAspect = sourceSize.width / sourceSize.height
        let containerAspect = containerSize.width / containerSize.height

        if containerAspect > sourceAspect {
            let height = containerSize.height
            let width = height * sourceAspect

            return CGRect(
                x: (containerSize.width - width) * 0.5,
                y: 0,
                width: width,
                height: height
            )
        }

        let width = containerSize.width
        let height = width / sourceAspect

        return CGRect(
            x: 0,
            y: (containerSize.height - height) * 0.5,
            width: width,
            height: height
        )
    }

    static func displayRect(
        normalizedRect: PosterNormalizedRect,
        imageRect: CGRect
    ) -> CGRect {
        CGRect(
            x: imageRect.minX + CGFloat(normalizedRect.x) * imageRect.width,
            y: imageRect.minY + CGFloat(normalizedRect.y) * imageRect.height,
            width: CGFloat(normalizedRect.width) * imageRect.width,
            height: CGFloat(normalizedRect.height) * imageRect.height
        )
    }

    static func realityKitRect(
        normalizedRect: PosterNormalizedRect,
        posterWidthMeters: Float,
        posterHeightMeters: Float
    ) -> (
        center: SIMD2<Float>,
        size: SIMD2<Float>
    ) {
        let centerNormalizedX = Float(
            normalizedRect.x + normalizedRect.width * 0.5
        )
        let centerNormalizedY = Float(
            normalizedRect.y + normalizedRect.height * 0.5
        )

        return (
            center: SIMD2<Float>(
                (centerNormalizedX - 0.5) * posterWidthMeters,
                (0.5 - centerNormalizedY) * posterHeightMeters
            ),
            size: SIMD2<Float>(
                Float(normalizedRect.width) * posterWidthMeters,
                Float(normalizedRect.height) * posterHeightMeters
            )
        )
    }
}
