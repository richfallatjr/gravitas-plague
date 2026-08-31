import Foundation
import simd

nonisolated struct MindEyeProjectionMaterialDescriptor: Sendable, Equatable {
    let clipFromSubject: simd_float4x4
    let projectorUVScaleX: Float
    let projectorUVScaleY: Float
    let projectorUVOffsetX: Float
    let projectorUVOffsetY: Float
    let emissionGain: Float
    let albedoSuppression: Float
    let specularSuppression: Float
    let fullQualityAngleRadians: Float
    let zeroProjectionAngleRadians: Float
    let frustumFeather: Float
    let receiverMaskConvention: MindEyeProjectionProfile.ReceiverMaskConvention
    let receiverUVSetIndex: Int
    let graphVersion: String

    init(profile: MindEyeProjectionProfile, camera: MindEyeProjectionCameraDescriptor) {
        clipFromSubject = camera.clipFromSubjectMatrix
        // The owner camera authored 1728-square plates, while the dynamic
        // runtime texture contains the exact 1440-square center crop. Preserve
        // that same camera by mapping full-camera UV into cropped-plate UV;
        // stretching the crop over the full frustum changes the authored lens.
        projectorUVScaleX = Float(profile.sourceWidth) / Float(profile.viewportWidth)
        projectorUVScaleY = Float(profile.sourceHeight) / Float(profile.viewportHeight)
        projectorUVOffsetX = -Float(profile.cropOriginX) / Float(profile.viewportWidth)
        projectorUVOffsetY = -Float(profile.cropOriginY) / Float(profile.viewportHeight)
        emissionGain = profile.projectionEmissionGain
        albedoSuppression = profile.albedoSuppression
        specularSuppression = profile.specularSuppression
        fullQualityAngleRadians = profile.fullQualityAngleDegrees * .pi / 180
        zeroProjectionAngleRadians = profile.zeroProjectionAngleDegrees * .pi / 180
        frustumFeather = 0.015
        receiverMaskConvention = profile.projectionReceiverUVMask.convention
        receiverUVSetIndex = profile.projectionReceiverUVMask.UVSetIndex
        graphVersion = "angel-camera-projector-uv-receiver/2"
    }
}

nonisolated enum MindEyeProjectionMaterialMath {
    struct Contributions: Sendable, Equatable {
        let coverage: Float
        let baseMultiplier: Float
        let specularMultiplier: Float
        let importedEmissionMultiplier: Float
        let projectedEmissionMultiplier: Float
    }

    static func contributions(
        receiverMaskLuminance: Float,
        projectedAlpha: Float,
        validProjectorPosition: Float,
        angleRadians: Float,
        frustumFade: Float,
        projectionEnabled: Float,
        descriptor: MindEyeProjectionMaterialDescriptor
    ) -> Contributions {
        let receiver = min(1, max(0, 1 - receiverMaskLuminance))
        let facing = 1 - smootherstep(
            descriptor.fullQualityAngleRadians,
            descriptor.zeroProjectionAngleRadians,
            angleRadians
        )
        let receiverVisibility = min(1, max(
            0,
            receiver * validProjectorPosition * facing *
                frustumFade * projectionEnabled
        ))
        let coverage = min(1, max(0, receiverVisibility * projectedAlpha))
        return Contributions(
            coverage: coverage,
            // The owner UV mask directly suppresses imported albedo inside the
            // valid projector region. Photographic alpha only controls the
            // projected contribution; it must not reveal the base face beneath
            // transparent/feathered plate pixels.
            baseMultiplier: 1 - receiverVisibility * descriptor.albedoSuppression,
            specularMultiplier: 1 - coverage * descriptor.specularSuppression,
            importedEmissionMultiplier: 1 - coverage,
            projectedEmissionMultiplier: coverage * descriptor.emissionGain
        )
    }

    static func smootherstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let u = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return u * u * u * (u * (u * 6 - 15) + 10)
    }
}
