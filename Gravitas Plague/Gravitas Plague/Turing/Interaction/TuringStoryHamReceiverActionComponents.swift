import RealityKit

struct TuringStoryHamReceiverPlayComponent:
    Component,
    Codable
{
}

struct TuringStoryHamReceiverMicrophoneComponent:
    Component,
    Codable
{
}

enum TuringStoryHamReceiverActionComponents {
    @MainActor
    private static var registered = false

    @MainActor
    static func registerIfNeeded() {
        guard registered == false else {
            return
        }
        TuringStoryHamReceiverPlayComponent
            .registerComponent()
        TuringStoryHamReceiverMicrophoneComponent
            .registerComponent()
        registered = true
    }
}
