import XCTest

@testable import Gravitas_Plague

final class MindEyeCompositeMaskOutputTests: XCTestCase {
    func testWhiteMaskKeepsOpaqueSubjectOpaque() {
        let output = MindEyeCompositeMathReference.applyMask(
            premultiplied: SIMD4<Float>(0.8, 0.4, 0.2, 1),
            maskRGB: SIMD3<Float>(repeating: 1)
        )

        XCTAssertEqual(output, SIMD4<Float>(0.8, 0.4, 0.2, 1))
    }

    func testBlackMaskMakesEdgeTransparentWithoutInvertingColor() {
        let output = MindEyeCompositeMathReference.applyMask(
            premultiplied: SIMD4<Float>(0.8, 0.4, 0.2, 1),
            maskRGB: .zero
        )

        XCTAssertEqual(output, SIMD4<Float>(0.8, 0.4, 0.2, 0))
    }

    func testMeasuredNearBlackBorderIsFullyTransparent() {
        let borderValue = Float(21) / 255
        let output = MindEyeCompositeMathReference.applyMask(
            premultiplied: SIMD4<Float>(0.8, 0.4, 0.2, 1),
            maskRGB: SIMD3<Float>(repeating: borderValue)
        )

        XCTAssertEqual(output.w, 0)
    }

    func testGrayMaskChangesAlphaWithoutMakingSubjectTranslucentTwice() {
        let output = MindEyeCompositeMathReference.applyMask(
            premultiplied: SIMD4<Float>(0.4, 0.2, 0.1, 0.5),
            maskRGB: SIMD3<Float>(repeating: 0.5)
        )

        XCTAssertEqual(output.x, 0.8, accuracy: 0.0001)
        XCTAssertEqual(output.y, 0.4, accuracy: 0.0001)
        XCTAssertEqual(output.z, 0.2, accuracy: 0.0001)
        XCTAssertEqual(
            output.w,
            0.5 * MindEyeCompositeMathReference.maskLuminance(
                SIMD3<Float>(repeating: 0.5)
            ),
            accuracy: 0.0001
        )
    }
}
