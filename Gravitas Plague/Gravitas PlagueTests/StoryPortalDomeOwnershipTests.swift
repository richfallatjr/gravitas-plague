import CoreGraphics
import RealityKit
import XCTest

@testable import Gravitas_Plague

@MainActor
final class StoryPortalDomeOwnershipTests: XCTestCase {
    func testOwnerPersistsAcrossSingleInstalledDome() throws {
        let ownerID = UUID()
        let root = Entity()
        let dome = try makeDome(ownerID: ownerID)
        root.addChild(dome)

        XCTAssertNoThrow(
            try PortalHDRIDomeRuntimeDiagnostics.validateExistingOwner(
                in: root,
                opening: .window,
                ownerID: ownerID
            )
        )
        XCTAssertThrowsError(
            try PortalHDRIDomeRuntimeDiagnostics.validateExistingOwner(
                in: root,
                opening: .window,
                ownerID: UUID()
            )
        )
    }

    func testDuplicateOpeningIsRejected() throws {
        let ownerID = UUID()
        let root = Entity()
        root.addChild(try makeDome(ownerID: ownerID))
        root.addChild(try makeDome(ownerID: ownerID))

        XCTAssertThrowsError(
            try PortalHDRIDomeRuntimeDiagnostics.validateExistingOwner(
                in: root,
                opening: .window,
                ownerID: ownerID
            )
        )
    }

    private func makeDome(ownerID: UUID) throws -> ModelEntity {
        try PortalHDRIDomeEntityFactory().makeDome(
            texture: try makeTexture(),
            atmosphereID: "test",
            visibleExposure: 1.0,
            providerType: "TestStoryWindow",
            opening: .window,
            ownerID: ownerID,
            placement: .storyOpening,
            surfaceContract: .storyInteriorOnly
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
        return try TextureResource(
            image: try XCTUnwrap(context.makeImage()),
            withName: "StoryPortalDomeOwnershipTests",
            options: .init(semantic: .color)
        )
    }
}
