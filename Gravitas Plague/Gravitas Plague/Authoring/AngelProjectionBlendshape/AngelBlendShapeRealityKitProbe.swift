#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation
import RealityKit
import simd

@MainActor
enum AngelBlendShapeRealityKitProbe {
    struct Binding: Sendable, Equatable {
        let entityPath: String
        let groupIndex: Int
        let weightIndex: Int
        let weightName: String
    }

    struct Report: Sendable, Equatable {
        let modelEntityCount: Int
        let bindings: [Binding]
        let importedMeshEvidence: [String]
        let testedWeights: [Float]
        let returnedToZero: Bool
    }

    static func run(
        root: Entity,
        targetName: String = "jawOpenProjection"
    ) throws -> Report {
        let resolved = try Chapter03AngelBlendShapeResolver().resolve(
            in: root,
            targetName: targetName
        )
        var importedMeshEvidence: [String] = []
        for binding in resolved {
            guard let entity = binding.entity,
                  let mesh = entity.model?.mesh else {
                throw Chapter03AngelBlendShapeError.entityReleased(
                    binding.entityPath
                )
            }
            for model in mesh.contents.models {
                for part in model.parts {
                    guard part.blendShapeNames.contains(targetName) else {
                        continue
                    }
                    let offsets = part.blendShapeOffsets(named: targetName)
                    let maximum = offsets?.elements.reduce(Float.zero) {
                        max($0, simd_length($1))
                    } ?? 0
                    importedMeshEvidence.append(
                        "entity=\(binding.entityPath) model=\(model.id) " +
                        "part=\(part.id) target=\(targetName) " +
                        "offsetCount=\(offsets?.count ?? 0) " +
                        "maximumOffset=\(maximum)"
                    )
                }
            }
        }
        let weights: [Float] = [0, 0.33, 0.5, 1, 0]
        for weight in weights {
            for binding in resolved {
                try binding.setWeight(weight)
            }
        }
        return Report(
            modelEntityCount: Set(resolved.map(\.entityPath)).count,
            bindings: resolved.map {
                Binding(
                    entityPath: $0.entityPath,
                    groupIndex: $0.groupIndex,
                    weightIndex: $0.weightIndex,
                    weightName: $0.weightName
                )
            },
            importedMeshEvidence: importedMeshEvidence,
            testedWeights: weights,
            returnedToZero: resolved.allSatisfy { binding in
                (try? binding.currentWeight()) == 0
            }
        )
    }
}
#endif
