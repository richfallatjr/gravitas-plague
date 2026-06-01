import Foundation
import RealityKit

struct JockSkeletonAdapter {
    struct ValidationReport: Equatable {
        let runtimeJointCount: Int
        let expectedJointCount: Int
        let matchedJointCount: Int
        let missingCanonicalJoints: [String]
        let runtimeJointNames: [String]

        var isUsable: Bool {
            matchedJointCount > 0 && missingCanonicalJoints.isEmpty
        }
    }

    let rig: JockRigDefinition
    let skeletonMap: JockSkeletonMap
    let runtimeJointNames: [String]
    let canonicalToRuntimeIndex: [String: Int]
    let validationReport: ValidationReport

    init(
        rig: JockRigDefinition,
        skeletonMap: JockSkeletonMap,
        runtimeJointNames: [String]
    ) {
        self.rig = rig
        self.skeletonMap = skeletonMap
        self.runtimeJointNames = runtimeJointNames

        var exactNameToIndex: [String: Int] = [:]
        var leafNameToIndex: [String: Int] = [:]

        for (index, runtimeName) in runtimeJointNames.enumerated() {
            exactNameToIndex[runtimeName] = index

            let leaf = Self.leafName(from: runtimeName)
            if leafNameToIndex[leaf] == nil {
                leafNameToIndex[leaf] = index
            }
        }

        var mapping: [String: Int] = [:]
        var missing: [String] = []

        for canonicalLeafName in rig.canonicalLeafNames {
            let sourceName = skeletonMap.sourceJointName(for: canonicalLeafName)

            if let index = exactNameToIndex[sourceName] {
                mapping[canonicalLeafName] = index
                continue
            }

            if let index = leafNameToIndex[sourceName] {
                mapping[canonicalLeafName] = index
                continue
            }

            if let index = exactNameToIndex[canonicalLeafName] {
                mapping[canonicalLeafName] = index
                continue
            }

            if let index = leafNameToIndex[canonicalLeafName] {
                mapping[canonicalLeafName] = index
                continue
            }

            missing.append(canonicalLeafName)
        }

        self.canonicalToRuntimeIndex = mapping
        self.validationReport = ValidationReport(
            runtimeJointCount: runtimeJointNames.count,
            expectedJointCount: rig.jointCount,
            matchedJointCount: mapping.count,
            missingCanonicalJoints: missing,
            runtimeJointNames: runtimeJointNames
        )
    }

    func runtimeIndex(for canonicalJointName: String) -> Int? {
        canonicalToRuntimeIndex[canonicalJointName]
    }

    private static func leafName(from name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }
}
