import RealityKit
import simd

@MainActor
enum Chapter03AngelBlendShapeMeshRepair {
    struct Report: Sendable, Equatable {
        let repairedPartCount: Int
        let alreadyValidPartCount: Int
        let maximumImportedOffset: Float
    }

    static func repairIfNeeded(
        root: Entity,
        targetName: String,
        payload: Chapter03AngelBlendShapeOffsetPayload
    ) throws -> Report {
        var repaired = 0
        var alreadyValid = 0
        var maximumImportedOffset: Float = 0
        var visited = Set<ObjectIdentifier>()

        try visit(root) { entity in
            guard let model = entity as? ModelEntity,
                  let mesh = model.model?.mesh,
                  visited.insert(ObjectIdentifier(mesh)).inserted else {
                return
            }
            var contents = mesh.contents
            var models = contents.models
            var meshChanged = false

            for sourceModel in contents.models {
                var destinationModel = sourceModel
                var parts = sourceModel.parts
                var modelChanged = false
                for sourcePart in sourceModel.parts {
                    guard sourcePart.blendShapeNames.contains(targetName),
                          let imported = sourcePart.blendShapeOffsets(named: targetName) else {
                        continue
                    }
                    let importedMaximum = imported.reduce(Float.zero) {
                        max($0, simd_length($1))
                    }
                    maximumImportedOffset = max(
                        maximumImportedOffset,
                        importedMaximum
                    )
                    if importedMaximum > 0.000_001 {
                        alreadyValid += 1
                        continue
                    }

                    let positions = sourcePart.positions.elements
                    let candidates = payload.meshes.filter {
                        $0.sourcePointCount <= positions.count &&
                        positions.count - $0.sourcePointCount <= 64
                    }
                    let matching = candidates.filter { candidate in
                        candidate.records.allSatisfy { record in
                            simd_distance(
                                positions[record.pointIndex],
                                record.basePosition
                            ) <= 0.000_002
                        }
                    }
                    guard matching.count == 1, let source = matching.first else {
                        throw Chapter03AngelBlendShapeError.meshRepairFailed(
                            "could not establish exact imported vertex registration"
                        )
                    }

                    var dense = [SIMD3<Float>](
                        repeating: .zero,
                        count: positions.count
                    )
                    for record in source.records {
                        dense[record.pointIndex] = record.offset
                    }
                    var destinationPart = sourcePart
                    destinationPart.setBlendShapeOffsets(
                        named: targetName,
                        buffer: MeshBuffers.BlendShapeOffsets(dense)
                    )
                    parts.update(destinationPart)
                    modelChanged = true
                    repaired += 1
                }
                if modelChanged {
                    destinationModel.parts = parts
                    models.update(destinationModel)
                    meshChanged = true
                }
            }
            if meshChanged {
                contents.models = models
                try mesh.replace(with: contents)
            }
        }

        guard repaired + alreadyValid > 0 else {
            throw Chapter03AngelBlendShapeError.meshRepairFailed(
                "no imported part exposes \(targetName)"
            )
        }
        return .init(
            repairedPartCount: repaired,
            alreadyValidPartCount: alreadyValid,
            maximumImportedOffset: maximumImportedOffset
        )
    }

    private static func visit(
        _ entity: Entity,
        body: (Entity) throws -> Void
    ) throws {
        try body(entity)
        for child in entity.children {
            try visit(child, body: body)
        }
    }
}
