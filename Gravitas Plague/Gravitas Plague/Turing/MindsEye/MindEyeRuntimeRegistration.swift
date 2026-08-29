import RealityKit

@MainActor
enum MindEyeRuntimeRegistration {
    private static var didRegister = false

    static func registerOnce() {
        guard !didRegister else { return }
        MindEyeMotionComponent.registerComponent()
        MindEyeMotionSystem.registerSystem()
        MindEyeAuthoredFramePlaybackComponent.registerComponent()
        MindEyeAuthoredFramePlaybackSystem.registerSystem()
        MindEyeGeneratedFramePlaybackComponent.registerComponent()
        MindEyeGeneratedFramePlaybackSystem.registerSystem()
        didRegister = true
        print("[MindEyeMotion] motion, authored, and generated playback systems registered")
    }
}
