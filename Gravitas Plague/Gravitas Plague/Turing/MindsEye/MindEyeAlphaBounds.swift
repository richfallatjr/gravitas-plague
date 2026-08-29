import Foundation

nonisolated struct MindEyeAlphaBounds: Sendable, Equatable {
    let minX: Int
    let minY: Int
    let maxXExclusive: Int
    let maxYExclusive: Int

    var width: Int { maxXExclusive - minX }
    var height: Int { maxYExclusive - minY }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    func padded(pixels: Int, canvasWidth: Int, canvasHeight: Int) -> Self {
        Self(
            minX: max(0, minX - pixels),
            minY: max(0, minY - pixels),
            maxXExclusive: min(canvasWidth, maxXExclusive + pixels),
            maxYExclusive: min(canvasHeight, maxYExclusive + pixels)
        )
    }

    func alignedOutward(
        multiple: Int,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> Self {
        guard multiple > 0 else { return self }
        let alignedMinX = (minX / multiple) * multiple
        let alignedMinY = (minY / multiple) * multiple
        let alignedMaxX = ((maxXExclusive + multiple - 1) / multiple) * multiple
        let alignedMaxY = ((maxYExclusive + multiple - 1) / multiple) * multiple
        return Self(
            minX: max(0, alignedMinX),
            minY: max(0, alignedMinY),
            maxXExclusive: min(canvasWidth, alignedMaxX),
            maxYExclusive: min(canvasHeight, alignedMaxY)
        )
    }

    var area: Int {
        guard !isEmpty else { return 0 }
        let product = width.multipliedReportingOverflow(by: height)
        return product.overflow ? Int.max : product.partialValue
    }
}
