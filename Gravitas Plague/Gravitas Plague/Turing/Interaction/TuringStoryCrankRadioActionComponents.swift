import RealityKit

struct TuringStoryCrankRadioPlayComponent:
    Component,
    Codable
{
}

struct TuringStoryCrankRadioMicrophoneComponent:
    Component,
    Codable
{
}

enum TuringStoryCrankRadioActionComponents {
    @MainActor
    private static var registered = false

    @MainActor
    static func registerIfNeeded() {
        guard registered == false else {
            return
        }
        TuringStoryCrankRadioPlayComponent
            .registerComponent()
        TuringStoryCrankRadioMicrophoneComponent
            .registerComponent()
        registered = true
    }
}
