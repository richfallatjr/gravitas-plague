import RealityKit

enum TuringRollingBenchDeviceID: String, Codable, Sendable {
    case crankRadio
    case hamReceiver
    case microphone
}

enum TuringRollingBenchDeviceAction: String, Codable, Sendable {
    case togglePlayback
    case toggleReceiver
    case beginMicrophoneHold
}

struct TuringRollingBenchDeviceActionComponent: Component, Codable {
    let deviceID: TuringRollingBenchDeviceID
    let action: TuringRollingBenchDeviceAction
}

@MainActor
enum TuringRollingBenchDeviceComponents {
    private static var registered = false

    static func registerIfNeeded() {
        guard !registered else { return }
        TuringRollingBenchDeviceActionComponent.registerComponent()
        registered = true
    }
}
