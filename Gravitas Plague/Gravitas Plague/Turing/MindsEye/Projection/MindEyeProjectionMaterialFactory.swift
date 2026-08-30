import Foundation
import RealityKit

/// The visionOS 27 SDK marks `CustomMaterial` unavailable. This factory keeps
/// projection target resolution and fail-soft ownership compile-valid while the
/// runtime material is authored as a supported ShaderGraphMaterial program.
@MainActor
enum MindEyeProjectionMaterialFactory {
    struct ApplicationReport: Sendable, Equatable {
        let resolvedMaterialCount: Int
        let appliedMaterialCount: Int
        let runtimeMaterialAvailable: Bool
    }

    static func validateTargets(
        target: MindEyeProjectionTargetDescriptor,
        on subjectRoot: Entity
    ) throws -> ApplicationReport {
        let resolution = try MindEyeProjectionTargetResolver.resolve(
            descriptor: target,
            subjectRoot: subjectRoot
        )
        return ApplicationReport(
            resolvedMaterialCount: resolution.materials.count,
            appliedMaterialCount: 0,
            runtimeMaterialAvailable: false
        )
    }
}
