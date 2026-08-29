import XCTest

@testable import Gravitas_Plague

final class MindEyePackedLayerBuilderTests: XCTestCase {
    func testAlphaBoundsPadAndAlignWithoutLeavingCanvas() throws {
        let width = 16
        let height = 12
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels[(5 * width + 7) * 4 + 3] = 255
        let raw = try MindEyePackedLayerBuilder.alphaBounds(
            rgba8: pixels,
            width: width,
            height: height
        )
        XCTAssertEqual(raw, MindEyeAlphaBounds(minX: 7, minY: 5, maxXExclusive: 8, maxYExclusive: 6))
        let retained = try MindEyePackedLayerBuilder.retainedBounds(
            rgba8: pixels,
            width: width,
            height: height
        )
        XCTAssertEqual(retained.minX % 4, 0)
        XCTAssertEqual(retained.minY % 4, 0)
        XCTAssertLessThanOrEqual(retained.maxXExclusive, width)
        XCTAssertLessThanOrEqual(retained.maxYExclusive, height)
        XCTAssertTrue(MindEyePackedLayerBuilder.shouldPack(
            bounds: retained,
            canvasWidth: width,
            canvasHeight: height,
            policy: .transparentOverlaysOnly
        ))
    }
}
