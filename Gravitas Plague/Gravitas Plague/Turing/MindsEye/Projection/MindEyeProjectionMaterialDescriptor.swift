import Foundation
import simd

nonisolated struct MindEyeProjectionMaterialDescriptor: Sendable, Equatable {
    let clipFromSubject: simd_float4x4
    let emissionGain: Float
    let albedoSuppression: Float
    let specularSuppression: Float
    let fullQualityAngleRadians: Float
    let zeroProjectionAngleRadians: Float
    let frustumFeather: Float

    init(profile: MindEyeProjectionProfile, camera: MindEyeProjectionCameraDescriptor) {
        clipFromSubject = camera.clipFromSubjectMatrix
        emissionGain = profile.projectionEmissionGain
        albedoSuppression = profile.albedoSuppression
        specularSuppression = profile.specularSuppression
        fullQualityAngleRadians = profile.fullQualityAngleDegrees * .pi / 180
        zeroProjectionAngleRadians = profile.zeroProjectionAngleDegrees * .pi / 180
        frustumFeather = 0.015
    }
}

nonisolated enum MindEyeProjectionMaterialMath {
    struct Contributions: Sendable, Equatable {
        let coverage: Float
        let baseMultiplier: Float
        let specularMultiplier: Float
        let emissionMultiplier: Float
    }

    static func contributions(mask: Float, alpha: Float, angleRadians: Float,
                              frustumFade: Float, descriptor: MindEyeProjectionMaterialDescriptor) -> Contributions {
        let facing = 1 - smootherstep(
            descriptor.fullQualityAngleRadians,
            descriptor.zeroProjectionAngleRadians,
            angleRadians
        )
        let coverage = min(1, max(0, mask * alpha * facing * frustumFade))
        return Contributions(
            coverage: coverage,
            baseMultiplier: 1 - coverage * descriptor.albedoSuppression,
            specularMultiplier: 1 - coverage * descriptor.specularSuppression,
            emissionMultiplier: coverage * descriptor.emissionGain
        )
    }

    static func smootherstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let u = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return u * u * u * (u * (u * 6 - 15) + 10)
    }
}
