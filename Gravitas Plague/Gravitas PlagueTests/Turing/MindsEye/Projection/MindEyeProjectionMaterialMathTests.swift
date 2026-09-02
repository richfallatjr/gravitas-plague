import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionMaterialMathTests: XCTestCase {
    func testAuthoredStraightRGBAUsesOneNukePremultBeforeOver() throws {
        let shaderURL = mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/Projection/Shaders/MindEyeProjectionPlateComposite.metal"
        )
        let source = try String(contentsOf: shaderURL, encoding: .utf8)

        XCTAssertTrue(source.contains("return half4(color.rgb * alpha, alpha);"))
        XCTAssertTrue(source.contains("over.rgb + under.rgb * inverseAlpha"))
        XCTAssertTrue(source.contains("over.a + under.a * inverseAlpha"))
        XCTAssertTrue(source.contains("selectedEyes.read(sourcePixel)"))
        XCTAssertTrue(source.contains("selectedMouth.read(sourcePixel)"))
        XCTAssertTrue(source.contains("projectionBase.read(sourcePixel)"))
        XCTAssertFalse(source.contains("overlaySourcePixel"))
        XCTAssertFalse(source.contains("clamp(color.rgb, half3(0.0), half3(alpha))"))
        XCTAssertFalse(source.contains("composed.rgb / composed.a"))
    }

    func testProjectionMaterialPreservesArtistAuthoredHorizontalOrientation() throws {
        let factoryURL = mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/Projection/MindEyeProjectionMaterialFactory.swift"
        )
        let source = try String(contentsOf: factoryURL, encoding: .utf8)

        XCTAssertFalse(source.contains("projectionSampleUHorizontalFlip"))
        XCTAssertTrue(source.contains(
            "try connect(u, to: projectedUV, input: \"in1\")"
        ))
    }

    func testInverseSuppressionEquation() throws {
        let descriptor = try descriptor()
        let zero = MindEyeProjectionMaterialMath.contributions(
            receiverMaskLuminance: 1,
            projectedAlpha: 1,
            validProjectorPosition: 1,
            projectionEnabled: 1,
            descriptor: descriptor
        )
        XCTAssertEqual(zero.baseMultiplier, 1)
        XCTAssertEqual(zero.specularMultiplier, 1)
        XCTAssertEqual(zero.importedEmissionMultiplier, 1)
        XCTAssertEqual(zero.projectedEmissionMultiplier, 0)

        let full = MindEyeProjectionMaterialMath.contributions(
            receiverMaskLuminance: 0,
            projectedAlpha: 1,
            validProjectorPosition: 1,
            projectionEnabled: 1,
            descriptor: descriptor
        )
        XCTAssertEqual(full.baseMultiplier, 0, accuracy: 0.0001)
        XCTAssertEqual(full.specularMultiplier, 0, accuracy: 0.0001)
        XCTAssertEqual(full.importedEmissionMultiplier, 0)
        XCTAssertEqual(full.projectedEmissionMultiplier, 1)
    }

    func testInvalidProjectorPositionRejectsProjectionWithoutAffectingReceiverMaskSuppression() throws {
        let result = MindEyeProjectionMaterialMath.contributions(
            receiverMaskLuminance: 0,
            projectedAlpha: 1,
            validProjectorPosition: 0,
            projectionEnabled: 1,
            descriptor: try descriptor()
        )

        XCTAssertEqual(result.coverage, 0, accuracy: 0.0001)
        XCTAssertEqual(result.baseMultiplier, 0, accuracy: 0.0001)
        XCTAssertEqual(result.specularMultiplier, 0, accuracy: 0.0001)
    }

    func testReceiverMaskSuppressesAlbedoIndependentlyFromPlateAlpha() throws {
        let result = MindEyeProjectionMaterialMath.contributions(
            receiverMaskLuminance: 0,
            projectedAlpha: 0,
            validProjectorPosition: 1,
            projectionEnabled: 1,
            descriptor: try descriptor()
        )

        XCTAssertEqual(result.coverage, 0, accuracy: 0.0001)
        XCTAssertEqual(result.baseMultiplier, 0, accuracy: 0.0001)
        XCTAssertEqual(result.specularMultiplier, 0, accuracy: 0.0001)
        XCTAssertEqual(result.importedEmissionMultiplier, 0, accuracy: 0.0001)
        XCTAssertEqual(result.projectedEmissionMultiplier, 0, accuracy: 0.0001)
    }

    func testReceiverMaskIsTheDirectMaterialMultiplier() throws {
        let result = MindEyeProjectionMaterialMath.contributions(
            receiverMaskLuminance: 0,
            projectedAlpha: 0,
            validProjectorPosition: 0,
            projectionEnabled: 1,
            descriptor: try descriptor()
        )

        XCTAssertEqual(result.coverage, 0, accuracy: 0.0001)
        XCTAssertEqual(result.baseMultiplier, 0, accuracy: 0.0001)
        XCTAssertEqual(result.specularMultiplier, 0, accuracy: 0.0001)
        XCTAssertEqual(result.importedEmissionMultiplier, 0, accuracy: 0.0001)
    }

    func testProjectorUsesExactAuthoredCameraCrop() throws {
        let descriptor = try descriptor()
        XCTAssertEqual(descriptor.projectorUVScaleX, 1.2, accuracy: 0.0001)
        XCTAssertEqual(descriptor.projectorUVScaleY, 1.2, accuracy: 0.0001)
        XCTAssertEqual(descriptor.projectorUVOffsetX, -0.1, accuracy: 0.0001)
        XCTAssertEqual(descriptor.projectorUVOffsetY, -0.1, accuracy: 0.0001)
    }

    private func descriptor() throws -> MindEyeProjectionMaterialDescriptor {
        MindEyeProjectionMaterialDescriptor(
            profile: try mindEyeProjectionProfileFixture(),
            camera: try mindEyeProjectionCameraFixture()
        )
    }
}
