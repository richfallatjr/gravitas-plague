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
        frustumFade: Float,
        projectionEnabled: Float,
        descriptor: MindEyeProjectionMaterialDescriptor
    ) -> Contributions {
        let receiver = min(1, max(0, 1 - receiverMaskLuminance))
        let receiverVisibility = min(1, max(
            0,
            receiver * validProjectorPosition *
                frustumFade * projectionEnabled
        ))
        let receiverMaskSuppression = min(
            1,
            max(0, receiver * projectionEnabled)
        )
        let coverage = min(1, max(0, receiverVisibility * projectedAlpha))
        return Contributions(
            coverage: coverage,
            // The owner UV mask is the direct material multiplier. A black mask
            // texel must produce zero imported albedo/specular even when the
            // photographic plate or projector safety fade has zero coverage.
            baseMultiplier:
                1 - receiverMaskSuppression * descriptor.albedoSuppression,
            specularMultiplier:
                1 - receiverMaskSuppression * descriptor.specularSuppression,
            // The projection material owns emission while active. The imported
            // eye-glow map is a fail-soft property of the restored PBR material,
            // never an additive layer underneath the photographic projection.
            importedEmissionMultiplier: 1 - min(1, max(0, projectionEnabled)),
            projectedEmissionMultiplier: coverage * descriptor.emissionGain
        )
    }

}
