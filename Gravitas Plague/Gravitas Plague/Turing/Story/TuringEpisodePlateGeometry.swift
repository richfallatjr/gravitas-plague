import CoreGraphics

enum TuringEpisodePlateGeometry {
    // The current authored plate is a 3072 x 2048 supersampled revision. The
    // aperture is the original audited aperture expressed proportionally.
    static let referenceSize = CGSize(width: 3072, height: 2048)
    static let transparentWindowNormalized = CGRect(
        x: 41.0 / 2048.0,
        y: 697.0 / 1365.0,
        width: 1968.0 / 2048.0,
        height: 601.0 / 1365.0
    )

    struct Layout: Equatable {
        let plateFrame: CGRect
        let contentFrame: CGRect
        let scale: CGFloat
    }

    static func layout(in containerSize: CGSize) -> Layout {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return Layout(plateFrame: .zero, contentFrame: .zero, scale: 0)
        }

        let scale = min(
            containerSize.width / referenceSize.width,
            containerSize.height / referenceSize.height
        )
        let fittedSize = CGSize(
            width: referenceSize.width * scale,
            height: referenceSize.height * scale
        )
        let plateOrigin = CGPoint(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2
        )
        let plateFrame = CGRect(origin: plateOrigin, size: fittedSize)
        let source = transparentWindowNormalized
        let contentFrame = CGRect(
            x: plateOrigin.x + fittedSize.width * source.minX,
            y: plateOrigin.y + fittedSize.height * source.minY,
            width: fittedSize.width * source.width,
            height: fittedSize.height * source.height
        )
        return Layout(
            plateFrame: plateFrame,
            contentFrame: contentFrame,
            scale: scale
        )
    }
}
