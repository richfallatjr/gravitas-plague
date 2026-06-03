import Foundation
import RealityKit
import simd

struct JockSkeletonWorldPoseResolver {
    let rig: JockRigDefinition
    let adapter: JockSkeletonAdapter

    private let parentByCanonicalLeaf: [String: String?]

    init(
        rig: JockRigDefinition,
        adapter: JockSkeletonAdapter
    ) {
        self.rig = rig
        self.adapter = adapter

        var parents: [String: String?] = [:]

        for path in rig.jointPaths {
            let components = path.split(separator: "/").map(String.init)

            guard let leaf = components.last else { continue }

            if components.count <= 1 {
                parents[leaf] = nil
            } else {
                parents[leaf] = components[components.count - 2]
            }
        }

        self.parentByCanonicalLeaf = parents
    }

    func worldPosition(
        for canonicalJointName: String,
        jointTransforms: [Transform],
        modelEntity: Entity
    ) -> SIMD3<Float>? {
        guard let localMatrix = localMatrixForJoint(
            canonicalJointName,
            jointTransforms: jointTransforms
        ) else {
            return nil
        }

        let modelWorld = modelEntity.transformMatrix(relativeTo: nil)
        let world = modelWorld * localMatrix
        let p = world.columns.3

        return SIMD3<Float>(p.x, p.y, p.z)
    }

    private func localMatrixForJoint(
        _ canonicalJointName: String,
        jointTransforms: [Transform]
    ) -> simd_float4x4? {
        guard let runtimeIndex = adapter.runtimeIndex(for: canonicalJointName),
              jointTransforms.indices.contains(runtimeIndex) else {
            return nil
        }

        let jointLocal = jointTransforms[runtimeIndex].matrix

        guard let parentName = parentByCanonicalLeaf[canonicalJointName] ?? nil else {
            return jointLocal
        }

        guard let parentMatrix = localMatrixForJoint(
            parentName,
            jointTransforms: jointTransforms
        ) else {
            return jointLocal
        }

        return parentMatrix * jointLocal
    }
}
