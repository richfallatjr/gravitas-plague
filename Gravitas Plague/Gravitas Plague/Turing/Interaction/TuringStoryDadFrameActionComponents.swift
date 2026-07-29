import RealityKit

struct TuringStoryDadFramePlayComponent: Component, Codable {
}

struct TuringStoryDadFrameMicrophoneComponent: Component, Codable {
}

enum TuringStoryDadFrameActionComponents {
    @MainActor
    private static var registered = false

    @MainActor
    static func registerIfNeeded() {
        guard registered == false else {
            return
        }
        TuringStoryDadFramePlayComponent.registerComponent()
        TuringStoryDadFrameMicrophoneComponent.registerComponent()
        registered = true
    }
}
