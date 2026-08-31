import Foundation
import RealityKit

nonisolated struct MindEyeProjectionMaterialPreparationReport: Sendable, Equatable {
    let resolvedMaterialCount: Int
    let preparedMaterialCount: Int
    let graphVersion: String
}

@MainActor
final class MindEyeProjectionMaterialPreparation {
    struct Target: @unchecked Sendable {
        let entity: Entity
        let entityPath: String
        let materialIndex: Int
        let originalMaterial: any Material
        let originalPBR: MindEyeProjectionImportedPBRSnapshot
        let replacement: ShaderGraphMaterial
    }

    let targets: [Target]
    let report: MindEyeProjectionMaterialPreparationReport

    init(
        targets: [Target],
        report: MindEyeProjectionMaterialPreparationReport
    ) {
        self.targets = targets
        self.report = report
    }
}
