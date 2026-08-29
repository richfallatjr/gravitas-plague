import Foundation

nonisolated enum MindEyeFailureCode:
    String,
    Sendable,
    Equatable,
    Hashable
{
    case phaseOneContractMissing
    case catalogMissing
    case catalogInvalid
    case speakerNotMapped
    case manifestMissing
    case manifestInvalid
    case unsafePath
    case assetMissing
    case assetZeroBytes
    case invalidPNG
    case wrongDimensions
    case invalidBackgroundAlpha
    case invalidOverlayAlpha
    case invalidFeatherMask
    case missingRequiredPose
    case noMetalDevice
    case textureLoadFailed
    case packageConstructionFailed
    case staleLoad
    case activePackageConflict
    case cancelled
    case memoryPressure
    case placementProviderConflict
    case placementProviderMissing
    case placementUnavailable
    case placementInvalid
    case staticCompositorUnavailable
    case staticCompositeFailed
    case outputTextureCreationFailed
    case textureResourceCreationFailed
    case presentationStale
    case invalidCompositeFrameState
    case invalidCompositeSelection
    case unsafeCompositeCrop
    case dynamicCompositorUnavailable
    case dynamicCompositeFailed
    case premultipliedMaterialUnavailable
    case invalidMotionTuning
    case invalidMotionSeed
    case invalidMotionProjection
    case invalidBlinkConfiguration
    case motionSurfaceUnavailable
    case motionRegistryUnavailable
    case motionComponentStale
    case motionSystemFailure
    case authoredFrameManifestInvalid
    case authoredFrameManifestUnsupported
    case authoredFrameManifestHashInvalid
    case authoredFrameIndexInvalid
    case authoredFrameIndexUnsupported
    case authoredFrameIndexHashInvalid
    case authoredFrameIndexMissing
    case authoredFrameManifestMissing
    case authoredFrameManifestHashMismatch
    case authoredFrameFramesHashMismatch
    case authoredFramePRMismatch
    case authoredFrameSpeakerMismatch
    case authoredFrameSurfaceMismatch
    case authoredFrameTrackInvalid
    case authoredFrameTrackUnavailable
    case authoredFrameTrackCacheConflict
    case authoredFrameClockInvalid
    case authoredMouthVariantPlanInvalid
    case authoredFramePlaybackUnavailable
    case authoredFramePlaybackInvalid
    case authoredFramePlaybackStale
    case authoredFrameRegistryUnavailable
    case authoredFrameSystemFailure
    case generatedFrameTrackInvalid
    case generatedFrameClockInvalid
    case generatedMouthVariantPlanInvalid
    case generatedMouthPlaybackUnavailable
    case generatedMouthPlaybackInvalid
    case generatedMouthPlaybackStale
    case generatedMouthRegistryUnavailable
    case generatedMouthSystemFailure
    case generatedMouthSpeakerMismatch
    case generatedMouthSurfaceMismatch
    case physicalPresenceClaimInvalid
    case physicalPresenceStateInvalid
    case lifecycleTransitionInvalid
    case memoryPressureSourceUnavailable
    case highMemoryPreflightInvariant
    case teardownInvariant
    case providerInvalidatedDuringPresentation
}

nonisolated struct MindEyeFailure:
    Error,
    Sendable,
    Equatable
{
    let code: MindEyeFailureCode
    let characterID: TuringConversationCharacterID?
    let vignetteID: String?
    let resourcePath: String?
    let message: String
}

nonisolated enum MindEyeAssetAcquisition:
    Sendable,
    Equatable
{
    case ready(MindEyeAssetLease)
    case unavailable(MindEyeFailure)
}
