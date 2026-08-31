import RealityKit
import XCTest
@testable import Gravitas_Plague

@MainActor
final class MindEyeProjectionRuntimeMaterialTests: XCTestCase {
    func testTargetPreflightDoesNotMutatePBRMaterial() throws {
        let root = Entity()
        root.name = "Chapter03PortalAngelRoot"
        let face = ModelEntity(
            mesh: .generateBox(size: SIMD3(0.3, 0.4, 0.25)),
            materials: [PhysicallyBasedMaterial()]
        )
        face.name = "AngelFace"
        root.addChild(face)
        let descriptor = MindEyeProjectionTargetDescriptor(
            schemaVersion: 1,
            profileID: "angel_head_v1",
            subjectRootEntityName: root.name,
            targetEntityPath: "Chapter03PortalAngelRoot/AngelFace",
            framingEntityPath: "Chapter03PortalAngelRoot/AngelFace",
            materials: [.init(
                entityPath: "Chapter03PortalAngelRoot/AngelFace",
                materialIndices: [0],
                expectedMaterialNames: ["PhysicallyBasedMaterial"]
            )],
            subjectForwardAxis: [0, 0, -1],
            targetLocalOffsetMeters: [0, 0, 0],
            requiredTargetMaterialCount: 1,
            authoringFramingControl: nil
        )
        let report = try MindEyeProjectionMaterialFactory.validateTargets(target: descriptor, on: root)
        XCTAssertEqual(report.resolvedMaterialCount, 1)
        XCTAssertEqual(report.appliedMaterialCount, 0)
        XCTAssertFalse(report.runtimeMaterialAvailable)
        XCTAssertTrue(face.model?.materials[0] is PhysicallyBasedMaterial)
    }

    func testProductionProjectionShaderGraphValidates() throws {
        let graph = try MindEyeProjectionShaderGraph.make(
            contract: mindEyeProjectionPBRContractFixture()
        )
        XCTAssertTrue(graph.validate())
    }

    func testReceiverMaskDiagnosticGraphValidates() throws {
        let graph = try MindEyeProjectionShaderGraph.make(
            contract: mindEyeProjectionPBRContractFixture(),
            diagnosticMode: .visualizeReceiverUVMask
        )
        XCTAssertTrue(graph.validate())
    }

    func testImportedPBRContractMatchesProfileAndTarget() throws {
        let contract = try mindEyeProjectionPBRContractFixture()
        XCTAssertNoThrow(
            try contract.validate(
                profile: mindEyeProjectionProfileFixture(),
                target: mindEyeProjectionTargetFixture()
            )
        )
        XCTAssertEqual(contract.graphVersion, "angel-camera-projector-uv-receiver/2")
        XCTAssertEqual(contract.normal.semantic, .tangentSpaceNormal)
        XCTAssertEqual(contract.normal.UVSetName, "primvars:st")
    }

    func testCheckedInParityQualificationRemainsClosedUntilThresholdsPass() throws {
        let qualification = try mindEyeProjectionParityFixture()
        XCTAssertFalse(qualification.passed)
        XCTAssertThrowsError(
            try qualification.validate(identities: .init(
                subjectAssetSHA256: qualification.subjectAssetSHA256,
                profileSHA256: qualification.profileSHA256,
                cameraSHA256: qualification.cameraSHA256,
                targetSHA256: qualification.targetSHA256,
                importedPBRContractSHA256: qualification.importedPBRContractSHA256
            ))
        )
    }
}
