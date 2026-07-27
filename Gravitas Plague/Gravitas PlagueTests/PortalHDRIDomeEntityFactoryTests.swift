import CoreGraphics
import RealityKit
import XCTest
import simd

@testable import Gravitas_Plague

@MainActor
final class PortalHDRIDomeEntityFactoryTests: XCTestCase {
    func testStoryDomeUsesAuthoredPlacementAndInteriorOnlySurface() throws {
        let ownerID = UUID()
        let dome = try PortalHDRIDomeEntityFactory().makeDome(
            texture: try makeTexture(),
            atmosphereID: "test",
            visibleExposure: 1.0,
            providerType: "TestStoryDoor",
            opening: .door,
            ownerID: ownerID,
            placement: .storyOpening,
            surfaceContract: .storyInteriorOnly
        )

        XCTAssertEqual(dome.position.x, 0, accuracy: 0.0001)
        XCTAssertEqual(dome.position.y, 0, accuracy: 0.0001)
        XCTAssertEqual(dome.position.z, -9, accuracy: 0.0001)
        XCTAssertEqual(dome.scale.x, 1, accuracy: 0.0001)
        XCTAssertEqual(dome.scale.y, 1, accuracy: 0.0001)
        XCTAssertEqual(dome.scale.z, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(simd_determinant(dome.transform.matrix), 0)

        let metadata = try XCTUnwrap(
            dome.components[PortalHDRIDomeRuntimeComponent.self]
        )
        XCTAssertEqual(metadata.opening, .door)
        XCTAssertEqual(metadata.ownerID, ownerID)
        XCTAssertEqual(metadata.radiusMeters, 12, accuracy: 0.0001)
        XCTAssertEqual(metadata.centerOffsetZ, -9, accuracy: 0.0001)
        XCTAssertEqual(metadata.nearestShellDistanceMeters, 3, accuracy: 0.0001)
        XCTAssertEqual(metadata.surfaceContract, .storyInteriorOnly)

        let model = try XCTUnwrap(dome.components[ModelComponent.self])
        let material = try XCTUnwrap(model.materials.first as? UnlitMaterial)
        XCTAssertEqual(material.faceCulling, .front)
    }

    func testStoryContractRejectsCenteredPlacement() throws {
        XCTAssertThrowsError(
            try PortalHDRIDomeEntityFactory().makeDome(
                texture: try makeTexture(),
                atmosphereID: "test",
                visibleExposure: 1.0,
                providerType: "TestStoryWindow",
                opening: .window,
                ownerID: UUID(),
                placement: .centeredLegacy,
                surfaceContract: .storyInteriorOnly
            )
        )
    }

    private func makeTexture() throws -> TextureResource {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: [1, 1, 1, 1]
            )!
        )
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try TextureResource(
            image: try XCTUnwrap(context.makeImage()),
            withName: "PortalHDRIDomeEntityFactoryTests",
            options: .init(semantic: .color)
        )
    }
}
