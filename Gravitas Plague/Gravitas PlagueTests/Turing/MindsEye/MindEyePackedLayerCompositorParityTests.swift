import simd
import XCTest

@testable import Gravitas_Plague

final class MindEyePackedLayerCompositorParityTests: XCTestCase {
    func testPackedLocalCoordinatesReconstructFullCanvasRegistration() {
        let rect = MindEyeLayerSourceRect(
            originPixels: SIMD2(192, 108),
            sizePixels: SIMD2(320, 180),
            canvasSizePixels: SIMD2(2304, 1296)
        )
        XCTAssertEqual(
            rect.canvasPixel(forLocalPixel: SIMD2(0, 0)),
            SIMD2(192, 108)
        )
        XCTAssertEqual(
            rect.canvasPixel(forLocalPixel: SIMD2(319, 179)),
            SIMD2(511, 287)
        )
        XCTAssertNil(rect.canvasPixel(forLocalPixel: SIMD2(320, 0)))
    }
}
