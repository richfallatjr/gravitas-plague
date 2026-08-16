import CoreGraphics
import RealityKit
import UIKit
import XCTest
@testable import Gravitas_Plague

@MainActor
final class Chapter03AngelEmissionApplierTests: XCTestCase {
    func testSetsExactOneAndPreservesImportedPBRState() throws {
        let texture = try makeTexture(name: "angel-emission-test")
        let normalTexture = try makeTexture(name: "angel-normal-test")
        var material = makeEmissiveMaterial(
            texture: texture,
            normalTexture: normalTexture,
            intensity: 0
        )
        material.baseColor = .init(
            tint: .red,
            texture: .init(texture)
        )
        material.metallic = .init(floatLiteral: 0.37)
        material.roughness = .init(floatLiteral: 0.62)
        material.opacityThreshold = 0.25
        material.faceCulling = .front
        material.blending = .transparent(opacity: 0.74)

        let modelEntity = makeModelEntity(material: material)
        let root = Entity()
        root.addChild(modelEntity)

        let report = try Chapter03AngelEmissionApplier.apply(
            to: root,
            assetName: "synthetic-angel.usdz"
        )
        let updated = try XCTUnwrap(pbrMaterial(from: modelEntity))

        XCTAssertEqual(updated.emissiveIntensity, 1.0)
        XCTAssertTrue(updated.emissiveColor.texture?.resource === texture)
        XCTAssertTrue(updated.baseColor.texture?.resource === texture)
        XCTAssertTrue(updated.normal.texture?.resource === normalTexture)
        XCTAssertTrue(updated.baseColor.tint.isEqual(UIColor.red))
        XCTAssertEqual(updated.metallic.scale, 0.37)
        XCTAssertEqual(updated.roughness.scale, 0.62)
        XCTAssertEqual(updated.opacityThreshold, 0.25)
        XCTAssertEqual(updated.faceCulling, .front)
        XCTAssertEqual(updated.blending, .transparent(opacity: 0.74))
        XCTAssertEqual(report.modelComponentsVisited, 1)
        XCTAssertEqual(report.materialsVisited, 1)
        XCTAssertEqual(report.pbrMaterialsVisited, 1)
        XCTAssertEqual(report.emissiveMaterialsUpdated, 1)
    }

    func testAssignsOneInsteadOfMultiplyingImportedValue() throws {
        let texture = try makeTexture(name: "angel-emission-assignment-test")
        let first = makeModelEntity(
            material: makeEmissiveMaterial(
                texture: texture,
                normalTexture: nil,
                intensity: 0
            )
        )
        let second = makeModelEntity(
            material: makeEmissiveMaterial(
                texture: texture,
                normalTexture: nil,
                intensity: 3
            )
        )
        let root = Entity()
        root.addChild(first)
        root.addChild(second)

        let report = try Chapter03AngelEmissionApplier.apply(
            to: root,
            assetName: "synthetic-angel.usdz"
        )

        XCTAssertEqual(pbrMaterial(from: first)?.emissiveIntensity, 1.0)
        XCTAssertEqual(pbrMaterial(from: second)?.emissiveIntensity, 1.0)
        XCTAssertEqual(report.emissiveMaterialsUpdated, 2)
    }

    func testIsIdempotentAtOne() throws {
        let texture = try makeTexture(name: "angel-emission-idempotence-test")
        let modelEntity = makeModelEntity(
            material: makeEmissiveMaterial(
                texture: texture,
                normalTexture: nil,
                intensity: 1
            )
        )
        let root = Entity()
        root.addChild(modelEntity)

        _ = try Chapter03AngelEmissionApplier.apply(
            to: root,
            assetName: "synthetic-angel.usdz"
        )
        _ = try Chapter03AngelEmissionApplier.apply(
            to: root,
            assetName: "synthetic-angel.usdz"
        )

        XCTAssertEqual(pbrMaterial(from: modelEntity)?.emissiveIntensity, 1.0)
    }

    func testThrowsWhenNoTextureBackedEmissionExists() {
        let modelEntity = makeModelEntity(material: PhysicallyBasedMaterial())
        let root = Entity()
        root.addChild(modelEntity)

        XCTAssertThrowsError(
            try Chapter03AngelEmissionApplier.apply(
                to: root,
                assetName: "missing-emission.usdz"
            )
        ) { error in
            guard case Chapter03AngelEmissionError.noEmissivePBRMaterial = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDoesNotMutateEntitiesOutsidePassedAngelRoot() throws {
        let texture = try makeTexture(name: "angel-emission-scope-test")
        let inside = makeModelEntity(
            material: makeEmissiveMaterial(
                texture: texture,
                normalTexture: nil,
                intensity: 3
            )
        )
        let outside = makeModelEntity(
            material: makeEmissiveMaterial(
                texture: texture,
                normalTexture: nil,
                intensity: 3
            )
        )
        let angelRoot = Entity()
        angelRoot.addChild(inside)

        _ = try Chapter03AngelEmissionApplier.apply(
            to: angelRoot,
            assetName: "synthetic-angel.usdz"
        )

        XCTAssertEqual(pbrMaterial(from: inside)?.emissiveIntensity, 1.0)
        XCTAssertEqual(pbrMaterial(from: outside)?.emissiveIntensity, 3.0)
    }

    private func makeEmissiveMaterial(
        texture: TextureResource,
        normalTexture: TextureResource?,
        intensity: Float
    ) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.emissiveColor = .init(
            color: .white,
            texture: .init(texture)
        )
        material.emissiveIntensity = intensity
        if let normalTexture {
            material.normal = .init(texture: .init(normalTexture))
        }
        return material
    }

    private func makeModelEntity(
        material: PhysicallyBasedMaterial
    ) -> ModelEntity {
        ModelEntity(
            mesh: .generateBox(size: 0.1),
            materials: [material]
        )
    }

    private func pbrMaterial(
        from entity: Entity
    ) -> PhysicallyBasedMaterial? {
        entity.components[ModelComponent.self]?
            .materials
            .first as? PhysicallyBasedMaterial
    }

    private func makeTexture(name: String) throws -> TextureResource {
        let bytes = Data([255, 255, 255, 255])
        let provider = try XCTUnwrap(
            CGDataProvider(data: bytes as CFData)
        )
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let image = try XCTUnwrap(
            CGImage(
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        return try TextureResource.generate(
            from: image,
            withName: name,
            options: .init(
                semantic: .color,
                mipmapsMode: .none
            )
        )
    }
}
