import Foundation

nonisolated protocol TuringPrerecordingOrientationDurationSampling: Sendable {
    func sampleSeconds() -> Double
}

nonisolated struct TuringSystemPrerecordingOrientationDurationSampler:
    TuringPrerecordingOrientationDurationSampling,
    Sendable
{
    func sampleSeconds() -> Double {
        Double.random(in: 2.0...5.0)
    }
}

nonisolated struct TuringFixedPrerecordingOrientationDurationSampler:
    TuringPrerecordingOrientationDurationSampling,
    Sendable
{
    let seconds: Double

    func sampleSeconds() -> Double { seconds }
}

nonisolated enum TuringPrerecordingOrientationEligibility {
    private static let excludedScriptPointIDs: Set<String> = [
        "chapter02.room.rich.windowRecognition.001",
        "chapter02.room.rich.womanBattle.001"
    ]

    static func permits(
        descriptor: TuringFlowDescriptor,
        role: TuringAuthoredMediaItem.Role
    ) -> Bool {
        guard role == .primaryPrerecording || role == .authoredBridge else {
            return false
        }
        return excludedScriptPointIDs.contains(descriptor.scriptPointID) == false
    }
}
