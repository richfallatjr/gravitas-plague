import Foundation
import RealityKit

struct Chapter03AngelEmissionReport: Sendable, Equatable {
    let modelComponentsVisited: Int
    let materialsVisited: Int
    let pbrMaterialsVisited: Int
    let emissiveMaterialsUpdated: Int
    let nonPBRMaterialTypes: [String]
}

enum Chapter03AngelEmissionError: LocalizedError {
    case noEmissivePBRMaterial(asset: String, materialTypes: [String])

    var errorDescription: String? {
        switch self {
        case let .noEmissivePBRMaterial(asset, materialTypes):
            return "No imported emissive PBR material was found in " +
                "\(asset). Material types: \(materialTypes)"
        }
    }
}

@MainActor
enum Chapter03AngelEmissionApplier {
    static let targetIntensity: Float = 1.0

    static func apply(
        to root: Entity,
        assetName: String
    ) throws -> Chapter03AngelEmissionReport {
        var modelComponentsVisited = 0
        var materialsVisited = 0
        var pbrMaterialsVisited = 0
        var emissiveMaterialsUpdated = 0
        var nonPBRMaterialTypes = Set<String>()

        visitRecursively(root) { entity in
            guard var model = entity.components[ModelComponent.self] else {
                return
            }

            modelComponentsVisited += 1
            var changed = false
            let updatedMaterials: [any Material] = model.materials.enumerated().map {
                index, material -> any Material in
                materialsVisited += 1
                let materialType = String(reflecting: type(of: material))

                guard var pbr = material as? PhysicallyBasedMaterial else {
                    nonPBRMaterialTypes.insert(materialType)
                    if let shaderGraph = material as? ShaderGraphMaterial {
                        print(
                            "[Chapter03AngelEmission] incompatible material " +
                                "asset=\(assetName) entity=\(entity.name) " +
                                "materialIndex=\(index) materialType=\(materialType) " +
                                "shaderParameters=\(shaderGraph.parameterNames.sorted())"
                        )
                    } else {
                        print(
                            "[Chapter03AngelEmission] incompatible material " +
                                "asset=\(assetName) entity=\(entity.name) " +
                                "materialIndex=\(index) materialType=\(materialType)"
                        )
                    }
                    return material
                }

                pbrMaterialsVisited += 1
                guard pbr.emissiveColor.texture != nil else {
                    print(
                        "[Chapter03AngelEmission] PBR has no emission texture " +
                            "asset=\(assetName) entity=\(entity.name) " +
                            "materialIndex=\(index) materialType=\(materialType) " +
                            "emissiveIntensity=\(pbr.emissiveIntensity)"
                    )
                    return material
                }

                let before = pbr.emissiveIntensity
                pbr.emissiveIntensity = targetIntensity
                emissiveMaterialsUpdated += 1
                changed = true

                print(
                    "[Chapter03AngelEmission] updated " +
                        "asset=\(assetName) entity=\(entity.name) " +
                        "materialIndex=\(index) materialType=\(materialType) " +
                        "hasEmissionTexture=true before=\(before) " +
                        "after=\(pbr.emissiveIntensity)"
                )
                return pbr
            }

            if changed {
                model.materials = updatedMaterials
                entity.components.set(model)
            }
        }

        let sortedNonPBRMaterialTypes = nonPBRMaterialTypes.sorted()
        guard emissiveMaterialsUpdated > 0 else {
            throw Chapter03AngelEmissionError.noEmissivePBRMaterial(
                asset: assetName,
                materialTypes: sortedNonPBRMaterialTypes
            )
        }

        let report = Chapter03AngelEmissionReport(
            modelComponentsVisited: modelComponentsVisited,
            materialsVisited: materialsVisited,
            pbrMaterialsVisited: pbrMaterialsVisited,
            emissiveMaterialsUpdated: emissiveMaterialsUpdated,
            nonPBRMaterialTypes: sortedNonPBRMaterialTypes
        )
        print(
            "[Chapter03AngelEmission] completed " +
                "asset=\(assetName) targetIntensity=\(targetIntensity) " +
                "modelComponentsVisited=\(report.modelComponentsVisited) " +
                "materialsVisited=\(report.materialsVisited) " +
                "pbrMaterialsVisited=\(report.pbrMaterialsVisited) " +
                "emissiveMaterialsUpdated=\(report.emissiveMaterialsUpdated)"
        )
        return report
    }

    private static func visitRecursively(
        _ entity: Entity,
        body: (Entity) -> Void
    ) {
        body(entity)
        for child in entity.children {
            visitRecursively(child, body: body)
        }
    }
}
