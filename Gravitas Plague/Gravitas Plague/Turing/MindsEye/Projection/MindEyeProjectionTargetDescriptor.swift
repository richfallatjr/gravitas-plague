import Foundation
import simd

nonisolated struct MindEyeProjectionTargetDescriptor: Codable, Sendable, Equatable {
    struct MaterialTarget: Codable, Sendable, Equatable {
        let entityPath: String
        let materialIndices: [Int]
        let expectedMaterialNames: [String]
    }

    struct AuthoringFramingControl: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let sourceAsset: String
        let sourceAssetSHA256: String
        let controlPrimPath: String
        let centerSubjectMeters: [Float]
        let rightAxisSubject: [Float]
        let upAxisSubject: [Float]
        let forwardAxisSubject: [Float]
        let halfExtentsMeters: [Float]

        func validate() throws {
            let vectors = [
                centerSubjectMeters,
                rightAxisSubject,
                upAxisSubject,
                forwardAxisSubject,
                halfExtentsMeters,
            ]
            guard schemaVersion == 1,
                  !sourceAsset.isEmpty,
                  sourceAssetSHA256.count == 64,
                  sourceAssetSHA256.allSatisfy(\.isHexDigit),
                  controlPrimPath.hasPrefix("/"),
                  vectors.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
                  halfExtentsMeters.allSatisfy({ (0.005 ... 0.375).contains($0) }) else {
                throw MindEyeProjectionError.invalidTargetDescriptor(
                    "invalid authoring framing control"
                )
            }
            let right = SIMD3<Float>(rightAxisSubject)
            let up = SIMD3<Float>(upAxisSubject)
            let forward = SIMD3<Float>(forwardAxisSubject)
            guard abs(simd_length(right) - 1) < 0.001,
                  abs(simd_length(up) - 1) < 0.001,
                  abs(simd_length(forward) - 1) < 0.001,
                  abs(simd_dot(right, up)) < 0.001,
                  abs(simd_dot(right, forward)) < 0.001,
                  abs(simd_dot(up, forward)) < 0.001,
                  simd_dot(simd_cross(forward, up), right) > 0.999 else {
                throw MindEyeProjectionError.invalidTargetDescriptor(
                    "authoring framing axes are not an orthonormal camera basis"
                )
            }
        }
    }

    let schemaVersion: Int
    let profileID: String
    let subjectRootEntityName: String
    let targetEntityPath: String
    let framingEntityPath: String?
    let materials: [MaterialTarget]
    let subjectForwardAxis: [Float]
    let targetLocalOffsetMeters: [Float]
    let requiredTargetMaterialCount: Int
    let authoringFramingControl: AuthoringFramingControl?

    var hasFacialSemanticEvidence: Bool {
        let values = [targetEntityPath, framingEntityPath ?? ""] +
            materials.flatMap { [$0.entityPath] + $0.expectedMaterialNames }
        return authoringFramingControl != nil || values.contains { value in
            let lower = value.lowercased()
            return lower.contains("face") || lower.contains("head") || lower.contains("skin")
        }
    }

    func validate() throws {
        guard schemaVersion == 1, profileID == "angel_head_v1",
              subjectRootEntityName == "Chapter03PortalAngelRoot",
              !targetEntityPath.isEmpty, !targetEntityPath.contains("<"),
              !materials.isEmpty, subjectForwardAxis.count == 3,
              targetLocalOffsetMeters.count == 3, requiredTargetMaterialCount > 0 else {
            throw MindEyeProjectionError.invalidTargetDescriptor("missing or placeholder identity")
        }
        let materialCount = materials.reduce(0) { $0 + $1.materialIndices.count }
        guard materialCount == requiredTargetMaterialCount,
              materials.allSatisfy({ !$0.entityPath.isEmpty && !$0.entityPath.contains("<") &&
                  !$0.materialIndices.isEmpty && $0.materialIndices.allSatisfy { $0 >= 0 } }) else {
            throw MindEyeProjectionError.invalidTargetDescriptor("material selection does not match required count")
        }
        let floats = subjectForwardAxis + targetLocalOffsetMeters
        guard floats.allSatisfy(\.isFinite) else {
            throw MindEyeProjectionError.invalidTargetDescriptor("non-finite vector")
        }
        try authoringFramingControl?.validate()
    }
}

private nonisolated extension SIMD3 where Scalar == Float {
    init(_ values: [Float]) {
        precondition(values.count == 3)
        self.init(values[0], values[1], values[2])
    }
}
