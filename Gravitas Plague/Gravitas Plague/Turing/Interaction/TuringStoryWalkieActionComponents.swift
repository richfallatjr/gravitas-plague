import RealityKit

struct TuringStoryWalkiePlayComponent: Component, Codable {
}

struct TuringStoryWalkieMicrophoneComponent: Component, Codable {
}

enum TuringStoryWalkieActionComponents {
    @MainActor
    private static var registered = false

    @MainActor
    static func registerIfNeeded() {
        guard registered == false else {
            return
        }

        TuringStoryWalkiePlayComponent.registerComponent()
        TuringStoryWalkieMicrophoneComponent.registerComponent()
        registered = true
    }
}

enum TuringStoryWalkiePresentation: Equatable {
    case hidden
    case play
    case microphone
    case microphoneRecovering
    case microphoneUnavailable

    init(gate: TuringFlowInteractionGateController.State) {
        switch gate {
        case .play:
            self = .play
        case .microphone:
            self = .microphone
        case .closed, .busy:
            self = .hidden
        }
    }
}
