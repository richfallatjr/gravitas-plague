import XCTest
import simd
@testable import Gravitas_Plague

final class Chapter03AngelBlendShapeTests: XCTestCase {
    func testLockedJawMappingIsIndependentFromHeavenEmberDensity() {
        XCTAssertEqual(Chapter03AngelJawPoseMapper.weight(for: .rest), 0)
        XCTAssertEqual(Chapter03AngelJawPoseMapper.weight(for: .teeth), 0)
        XCTAssertEqual(Chapter03AngelJawPoseMapper.weight(for: .small), 0.33)
        XCTAssertEqual(Chapter03AngelJawPoseMapper.weight(for: .round), 0.5)
        XCTAssertEqual(Chapter03AngelJawPoseMapper.weight(for: .wide), 1)
        XCTAssertEqual(PortalFXVisemeDensityMapper.multiplier(for: .teeth), 1.75)
        XCTAssertNotEqual(
            Chapter03AngelJawPoseMapper.weight(for: .teeth),
            PortalFXVisemeDensityMapper.multiplier(for: .teeth)
        )
    }

    func testResponseIsMonotonicAndDoesNotOvershoot() {
        let response = productionResponse()
        var opening: Float = 0
        for _ in 0..<120 {
            let next = response.step(
                current: opening,
                target: 1,
                deltaTime: 1 / 60
            )
            XCTAssertGreaterThanOrEqual(next, opening)
            XCTAssertLessThanOrEqual(next, 1)
            opening = next
        }
        XCTAssertEqual(opening, 1, accuracy: response.assignmentEpsilon)

        var closing = opening
        for _ in 0..<120 {
            let next = response.step(
                current: closing,
                target: 0,
                deltaTime: 1 / 60
            )
            XCTAssertLessThanOrEqual(next, closing)
            XCTAssertGreaterThanOrEqual(next, 0)
            closing = next
        }
        XCTAssertEqual(closing, 0, accuracy: response.assignmentEpsilon)
    }

    func testResponseClampsDeltaAndAgreesAcrossFrameRates() {
        let response = productionResponse()
        XCTAssertEqual(
            response.step(current: 0.25, target: 1, deltaTime: 0),
            0.25
        )
        XCTAssertEqual(
            response.step(current: 0.25, target: 1, deltaTime: -1),
            0.25
        )
        XCTAssertEqual(
            response.step(current: 0, target: 1, deltaTime: 1),
            response.step(current: 0, target: 1, deltaTime: 0.05),
            accuracy: 0.000_001
        )

        let at30 = integrate(response: response, hertz: 30, seconds: 0.25)
        let at60 = integrate(response: response, hertz: 60, seconds: 0.25)
        let at90 = integrate(response: response, hertz: 90, seconds: 0.25)
        XCTAssertEqual(at30, at60, accuracy: 0.001)
        XCTAssertEqual(at60, at90, accuracy: 0.001)
    }

    func testProductionDescriptorLocksCorrectedTeethZero() throws {
        let root = try repositoryRoot()
        let url = root.appendingPathComponent(
            "Gravitas Plague/TuringResources/Turing/Chapter03/" +
                "AngelProjection/angel_jaw_open_projection.json"
        )
        let descriptor = try JSONDecoder().decode(
            Chapter03AngelBlendShapeDescriptor.self,
            from: Data(contentsOf: url)
        )
        XCTAssertNoThrow(try descriptor.validate())
        XCTAssertEqual(descriptor.poseWeights.teeth, 0)
        XCTAssertEqual(descriptor.poseWeights.small, 0.5)
        XCTAssertEqual(descriptor.poseWeights.round, 0.5)
        XCTAssertEqual(descriptor.poseWeights.wide, 1)
        XCTAssertTrue(descriptor.requiresProjectionReady)
    }

    func testProductionOffsetPayloadIsHashBoundAndSparse() throws {
        let root = try repositoryRoot()
        let descriptorURL = root.appendingPathComponent(
            "Gravitas Plague/TuringResources/Turing/Chapter03/" +
                "AngelProjection/angel_jaw_open_projection.json"
        )
        let descriptor = try JSONDecoder().decode(
            Chapter03AngelBlendShapeDescriptor.self,
            from: Data(contentsOf: descriptorURL)
        )
        let payloadURL = root.appendingPathComponent(
            "Gravitas Plague/TuringResources/" +
                descriptor.offsetPayloadResourcePath
        )
        let payload = try Chapter03AngelBlendShapeOffsetPayload(
            data: Data(contentsOf: payloadURL),
            expectedMeshCount: descriptor.offsetPayloadMeshCount,
            expectedRecordCount: descriptor.offsetPayloadRecordCount
        )
        XCTAssertEqual(payload.meshes.count, 1)
        XCTAssertEqual(payload.meshes[0].sourcePointCount, 1_062_657)
        XCTAssertEqual(
            payload.meshes[0].records.count,
            descriptor.offsetPayloadRecordCount
        )
        XCTAssertEqual(
            payload.meshes[0].records.map(\.pointIndex),
            payload.meshes[0].records.map(\.pointIndex).sorted()
        )
        XCTAssertGreaterThan(
            payload.meshes[0].records.map { simd_length($0.offset) }.max() ?? 0,
            0.011
        )
    }

    func testOffsetPayloadRejectsTruncation() throws {
        let root = try repositoryRoot()
        let descriptorURL = root.appendingPathComponent(
            "Gravitas Plague/TuringResources/Turing/Chapter03/" +
                "AngelProjection/angel_jaw_open_projection.json"
        )
        let descriptor = try JSONDecoder().decode(
            Chapter03AngelBlendShapeDescriptor.self,
            from: Data(contentsOf: descriptorURL)
        )
        let url = root.appendingPathComponent(
            "Gravitas Plague/TuringResources/Turing/Chapter03/" +
                "AngelProjection/angel_jaw_open_projection_offsets.bin"
        )
        let truncated = Data(try Data(contentsOf: url).dropLast())
        XCTAssertThrowsError(try Chapter03AngelBlendShapeOffsetPayload(
            data: truncated,
            expectedMeshCount: descriptor.offsetPayloadMeshCount,
            expectedRecordCount: descriptor.offsetPayloadRecordCount
        ))
    }

    func testVisualProjectionOwnsEmissionWithoutDependingOnBlendShape() {
        let visualOnly = Chapter03AngelProjectionReadiness(
            cameraReady: true,
            materialReady: true,
            textureReady: true,
            maskReady: true,
            blendShapeReady: false
        )
        XCTAssertTrue(visualOnly.isVisualProjectionReady)
        XCTAssertFalse(visualOnly.isReady)

        let missingMask = Chapter03AngelProjectionReadiness(
            cameraReady: true,
            materialReady: true,
            textureReady: true,
            maskReady: false,
            blendShapeReady: true
        )
        XCTAssertFalse(missingMask.isVisualProjectionReady)
        XCTAssertFalse(missingMask.isReady)
    }

    private func productionResponse() -> Chapter03AngelBlendShapeResponse {
        Chapter03AngelBlendShapeResponse(
            openingHalfLifeSeconds: 0.03,
            closingHalfLifeSeconds: 0.05,
            crossingHalfLifeSeconds: 0.035,
            maximumDeltaTimeSeconds: 0.05,
            assignmentEpsilon: 0.0005
        )
    }

    private func integrate(
        response: Chapter03AngelBlendShapeResponse,
        hertz: Int,
        seconds: Float
    ) -> Float {
        var value: Float = 0
        let steps = Int(seconds * Float(hertz))
        for _ in 0..<steps {
            value = response.step(
                current: value,
                target: 1,
                deltaTime: 1 / Float(hertz)
            )
        }
        return value
    }

    private func repositoryRoot() throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/", cursor.lastPathComponent != "gravitas-plague" {
            cursor.deleteLastPathComponent()
        }
        guard cursor.lastPathComponent == "gravitas-plague" else {
            throw CocoaError(.fileNoSuchFile)
        }
        return cursor
    }
}
