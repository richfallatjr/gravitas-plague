import RealityKit
import XCTest
@testable import Gravitas_Plague

@MainActor
final class MindEyeProjectionTargetResolverTests: XCTestCase {
    func testExplicitFaceTargetResolvesOnlySelectedMaterial() throws {
        let root = Entity()
        root.name = "Chapter03PortalAngelRoot"
        let face = ModelEntity(
            mesh: .generateBox(size: SIMD3(0.3, 0.4, 0.25)),
            materials: [PhysicallyBasedMaterial()]
        )
        face.name = "AngelFace"
        root.addChild(face)
        let descriptor = descriptor(path: "Chapter03PortalAngelRoot/AngelFace")
        let resolution = try MindEyeProjectionTargetResolver.resolve(
            descriptor: descriptor,
            subjectRoot: root
        )
        XCTAssertEqual(resolution.materials.count, 1)
        XCTAssertTrue(resolution.materials[0].entity === face)
    }

    func testWholeBodyGenericTargetIsRejected() throws {
        let root = Entity()
        root.name = "Chapter03PortalAngelRoot"
        let body = ModelEntity(
            mesh: .generateBox(size: SIMD3(0.8, 1.9, 0.6)),
            materials: [PhysicallyBasedMaterial()]
        )
        body.name = "mesh1"
        root.addChild(body)
        XCTAssertThrowsError(try MindEyeProjectionTargetResolver.resolve(
            descriptor: descriptor(path: "Chapter03PortalAngelRoot/mesh1"),
            subjectRoot: root
        ))
    }

    private func descriptor(path: String) -> MindEyeProjectionTargetDescriptor {
        .init(
            schemaVersion: 1,
            profileID: "angel_head_v1",
            subjectRootEntityName: "Chapter03PortalAngelRoot",
            targetEntityPath: path,
            framingEntityPath: path,
            materials: [.init(
                entityPath: path,
                materialIndices: [0],
                expectedMaterialNames: ["PhysicallyBasedMaterial"]
            )],
            subjectForwardAxis: [0, 0, -1],
            targetLocalOffsetMeters: [0, 0, 0],
            requiredTargetMaterialCount: 1,
            authoringFramingControl: nil
        )
    }
}
