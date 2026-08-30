#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation
import RealityKit

@MainActor
enum MindEyeProjectionHierarchyReporter {
    struct Report {
        let text: String
        let candidate: MindEyeProjectionTargetDescriptor
    }

    private struct ModelRecord {
        let entity: Entity
        let path: String
        let materialTypes: [String]
        let score: Int
    }

    static func make(subjectRoot: Entity) throws -> Report {
        var lines: [String] = []
        var models: [ModelRecord] = []
        visit(subjectRoot, root: subjectRoot, path: subjectRoot.name, lines: &lines, models: &models)
        guard let selected = models.sorted(by: {
            $0.score == $1.score ? $0.path < $1.path : $0.score > $1.score
        }).first else {
            throw MindEyeProjectionError.targetResolutionFailed("Angel contains no ModelComponent")
        }
        let indices = Array(selected.materialTypes.indices)
        let materialTarget = MindEyeProjectionTargetDescriptor.MaterialTarget(
            entityPath: selected.path,
            materialIndices: indices,
            expectedMaterialNames: selected.materialTypes
        )
        let candidate = MindEyeProjectionTargetDescriptor(
            schemaVersion: 1,
            profileID: "angel_head_v1",
            subjectRootEntityName: subjectRoot.name,
            targetEntityPath: selected.path,
            framingEntityPath: selected.path,
            materials: [materialTarget],
            // Simulator frame-zero inspection proves the posed asset's face is
            // presented from the subject-root -Z axis.
            subjectForwardAxis: [0, 0, -1],
            targetLocalOffsetMeters: [0, 0, 0],
            requiredTargetMaterialCount: indices.count,
            authoringFramingControl: nil
        )
        try candidate.validate()
        let selectedBounds = selected.entity.visualBounds(relativeTo: subjectRoot)
        let extents = selectedBounds.max - selectedBounds.min
        let headSized = extents.x <= 0.75 && extents.y <= 0.75 && extents.z <= 0.75
        let eligible = candidate.hasFacialSemanticEvidence || headSized
        lines.append(
            "FACIAL_TARGET_EVIDENCE semantic=\(candidate.hasFacialSemanticEvidence) " +
            "headSized=\(headSized) eligible=\(eligible) extents=\(extents)"
        )
        if !eligible {
            lines.append(
                "FACIAL_TARGET_BLOCKER selected model is whole-body geometry; " +
                "author a separate named face/head/skin entity or material slot"
            )
        }
        lines.append("RECOMMENDED_PROJECTION_TARGET \(selected.path) materials=\(indices)")
        return Report(text: lines.joined(separator: "\n") + "\n", candidate: candidate)
    }

    private static func visit(
        _ entity: Entity,
        root: Entity,
        path: String,
        lines: inout [String],
        models: inout [ModelRecord]
    ) {
        let bounds = entity.visualBounds(relativeTo: root)
        let matrix = entity.transformMatrix(relativeTo: root).columnMajorValues
            .map { String(format: "%.6f", $0) }.joined(separator: ",")
        if let model = entity.components[ModelComponent.self] {
            let types = model.materials.map { shortMaterialName($0) }
            lines.append(
                "MODEL path=\(path) materials=\(types) boundsMin=\(bounds.min) boundsMax=\(bounds.max) transform=[\(matrix)]"
            )
            let lower = path.lowercased()
            let score = (lower.contains("face") ? 1_000 : 0) +
                (lower.contains("head") ? 800 : 0) +
                (lower.contains("skin") ? 600 : 0) +
                (lower.contains("eye") ? -300 : 0) +
                (lower.contains("hair") ? -300 : 0) + types.count
            models.append(ModelRecord(entity: entity, path: path, materialTypes: types, score: score))
        } else {
            lines.append("ENTITY path=\(path) type=\(String(reflecting: type(of: entity))) transform=[\(matrix)]")
        }
        for child in entity.children.sorted(by: { $0.name < $1.name }) {
            visit(child, root: root, path: path + "/" + child.name, lines: &lines, models: &models)
        }
    }

    private static func shortMaterialName(_ material: any Material) -> String {
        String(reflecting: type(of: material)).split(separator: ".").last.map(String.init) ?? "Material"
    }
}
#endif
