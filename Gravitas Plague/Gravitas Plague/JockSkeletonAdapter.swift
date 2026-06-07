import Foundation
import RealityKit

enum JockJointMatchKind: String, Codable {
    case exactFullPath
    case uniqueLeafName
    case missing
    case ambiguousLeafName
}

struct JockJointMappingRecord: Codable {
    let canonicalPath: String
    let canonicalLeaf: String

    let runtimeIndex: Int?
    let runtimeJointName: String?
    let runtimeFullPath: String?

    let matchKind: JockJointMatchKind
}

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
    let mappingRecords: [JockJointMappingRecord]
    let validationReport: ValidationReport

    init(
        rig: JockRigDefinition,
        skeletonMap: JockSkeletonMap,
        runtimeJointNames: [String]
    ) {
        self.rig = rig
        self.skeletonMap = skeletonMap
        self.runtimeJointNames = runtimeJointNames

        var mapping: [String: Int] = [:]
        var unmatched: [String] = []
        let records = Self.buildMapping(
            canonicalJointPaths: rig.jointPaths,
            runtimeJointNames: runtimeJointNames
        )

        for record in records {
            switch record.matchKind {
            case .exactFullPath, .uniqueLeafName:
                if let runtimeIndex = record.runtimeIndex {
                    mapping[record.canonicalLeaf] = runtimeIndex
                }
            case .missing, .ambiguousLeafName:
                unmatched.append(record.canonicalPath)
            }
        }

        self.canonicalToRuntimeIndex = mapping
        self.mappingRecords = records
        self.validationReport = ValidationReport(
            runtimeJointCount: runtimeJointNames.count,
            expectedJointCount: rig.jointCount,
            matchedJointCount: mapping.count,
            missingCanonicalJoints: unmatched,
            runtimeJointNames: runtimeJointNames
        )
    }

    func runtimeIndex(for canonicalJointName: String) -> Int? {
        canonicalToRuntimeIndex[canonicalJointName]
    }

    func runtimeJointName(
        for canonicalJointName: String
    ) -> String? {
        guard let runtimeIndex = runtimeIndex(for: canonicalJointName),
              runtimeJointNames.indices.contains(runtimeIndex) else {
            return nil
        }

        return runtimeJointNames[runtimeIndex]
    }

    static func buildMapping(
        canonicalJointPaths: [String],
        runtimeJointNames: [String]
    ) -> [JockJointMappingRecord] {
        let normalizedRuntime = runtimeJointNames.map {
            normalizedJointPath($0)
        }

        var runtimeIndexByFullPath: [String: Int] = [:]
        var runtimeIndicesByLeaf: [String: [Int]] = [:]

        for (index, runtimePath) in normalizedRuntime.enumerated() {
            runtimeIndexByFullPath[runtimePath] = index

            let leaf = leafName(runtimePath)
            runtimeIndicesByLeaf[leaf, default: []].append(index)
        }

        var records: [JockJointMappingRecord] = []

        for canonicalPathRaw in canonicalJointPaths {
            let canonicalPath = normalizedJointPath(canonicalPathRaw)
            let canonicalLeaf = leafName(canonicalPath)

            if let exactIndex = runtimeIndexByFullPath[canonicalPath] {
                records.append(
                    JockJointMappingRecord(
                        canonicalPath: canonicalPath,
                        canonicalLeaf: canonicalLeaf,
                        runtimeIndex: exactIndex,
                        runtimeJointName: leafName(normalizedRuntime[exactIndex]),
                        runtimeFullPath: normalizedRuntime[exactIndex],
                        matchKind: .exactFullPath
                    )
                )

                continue
            }

            let leafMatches = runtimeIndicesByLeaf[canonicalLeaf] ?? []

            if leafMatches.count == 1,
               let index = leafMatches.first {
                records.append(
                    JockJointMappingRecord(
                        canonicalPath: canonicalPath,
                        canonicalLeaf: canonicalLeaf,
                        runtimeIndex: index,
                        runtimeJointName: leafName(normalizedRuntime[index]),
                        runtimeFullPath: normalizedRuntime[index],
                        matchKind: .uniqueLeafName
                    )
                )

                continue
            }

            if leafMatches.count > 1 {
                records.append(
                    JockJointMappingRecord(
                        canonicalPath: canonicalPath,
                        canonicalLeaf: canonicalLeaf,
                        runtimeIndex: nil,
                        runtimeJointName: nil,
                        runtimeFullPath: nil,
                        matchKind: .ambiguousLeafName
                    )
                )

                continue
            }

            records.append(
                JockJointMappingRecord(
                    canonicalPath: canonicalPath,
                    canonicalLeaf: canonicalLeaf,
                    runtimeIndex: nil,
                    runtimeJointName: nil,
                    runtimeFullPath: nil,
                    matchKind: .missing
                )
            )
        }

        return records
    }

    static func validateMappingRecords(
        _ records: [JockJointMappingRecord],
        archetype: PlagueCharacterArchetype
    ) {
        var matched = 0
        var missing: [String] = []
        var ambiguous: [String] = []
        var criticalMismatches: [String] = []

        for record in records {
            switch record.matchKind {
            case .exactFullPath, .uniqueLeafName:
                matched += 1

                if identityMapCriticalJoints.contains(record.canonicalLeaf),
                   record.runtimeJointName != record.canonicalLeaf {
                    criticalMismatches.append(
                        "\(record.canonicalPath) -> \(record.runtimeFullPath ?? "nil")"
                    )
                }

            case .missing:
                missing.append(record.canonicalPath)

            case .ambiguousLeafName:
                ambiguous.append(record.canonicalPath)
            }
        }

        print(
            """
            [JockSkeletonAdapter] mapping diagnostics
              archetype: \(archetype.rawValue)
              records: \(records.count)
              matched: \(matched)
              missing: \(missing.count)
              ambiguous: \(ambiguous.count)
              criticalMismatches: \(criticalMismatches.count)
            """
        )

        for record in records {
            print(
                """
                [JockSkeletonAdapter] joint map
                  canonicalPath: \(record.canonicalPath)
                  canonicalLeaf: \(record.canonicalLeaf)
                  runtimeIndex: \(record.runtimeIndex.map(String.init) ?? "nil")
                  runtimeJointName: \(record.runtimeJointName ?? "nil")
                  runtimeFullPath: \(record.runtimeFullPath ?? "nil")
                  matchKind: \(record.matchKind.rawValue)
                """
            )
        }

        if !missing.isEmpty {
            print(
                """
                [JockSkeletonAdapter] ERROR missing joints
                  archetype: \(archetype.rawValue)
                  joints: \(missing.joined(separator: ", "))
                """
            )
        }

        if !ambiguous.isEmpty {
            print(
                """
                [JockSkeletonAdapter] ERROR ambiguous leaf-name joints
                  archetype: \(archetype.rawValue)
                  joints: \(ambiguous.joined(separator: ", "))
                """
            )
        }

        if !criticalMismatches.isEmpty {
            print(
                """
                [JockSkeletonAdapter] ERROR critical identity-map mismatch
                  archetype: \(archetype.rawValue)
                  mismatches:
                  \(criticalMismatches.joined(separator: "\n"))
                """
            )
        }
    }

    private static let identityMapCriticalJoints: Set<String> = [
        "Hips",
        "Spine02",
        "Spine01",
        "Spine"
    ]

    private static func leafName(_ path: String) -> String {
        path
            .split(separator: "/")
            .last
            .map(String.init)
            ?? path
    }

    private static func normalizedJointPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
