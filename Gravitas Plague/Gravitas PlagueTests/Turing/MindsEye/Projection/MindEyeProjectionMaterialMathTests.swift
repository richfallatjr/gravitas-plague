import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionMaterialMathTests: XCTestCase {
    func testInverseSuppressionEquation() throws {
        let descriptor = try descriptor()
        let zero = MindEyeProjectionMaterialMath.contributions(
            mask: 0, alpha: 1, angleRadians: 0, frustumFade: 1, descriptor: descriptor
        )
        XCTAssertEqual(zero.baseMultiplier, 1)
        XCTAssertEqual(zero.specularMultiplier, 1)
        XCTAssertEqual(zero.emissionMultiplier, 0)

        let full = MindEyeProjectionMaterialMath.contributions(
            mask: 1, alpha: 1, angleRadians: 0, frustumFade: 1, descriptor: descriptor
        )
        XCTAssertEqual(full.baseMultiplier, 0.04, accuracy: 0.0001)
        XCTAssertEqual(full.specularMultiplier, 0.1, accuracy: 0.0001)
        XCTAssertEqual(full.emissionMultiplier, 1)
    }

    func testViewConeFadesToPhysicalMaterial() throws {
        let descriptor = try descriptor()
        let cutoff = MindEyeProjectionMaterialMath.contributions(
            mask: 1, alpha: 1, angleRadians: 42 * .pi / 180,
            frustumFade: 1, descriptor: descriptor
        )
        XCTAssertEqual(cutoff.coverage, 0, accuracy: 0.0001)
    }

    private func descriptor() throws -> MindEyeProjectionMaterialDescriptor {
        MindEyeProjectionMaterialDescriptor(
            profile: try mindEyeProjectionProfileFixture(),
            camera: try mindEyeProjectionCameraFixture()
        )
    }
}
