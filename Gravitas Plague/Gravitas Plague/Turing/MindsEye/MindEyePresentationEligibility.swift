import Foundation

nonisolated enum MindEyePresentationEligibilityDecision:
    Sendable,
    Equatable
{
    case eligible
    case suppressed(reason: String)
}

nonisolated protocol MindEyePresentationEligibilityChecking: Sendable {
    func decision(
        for context: TuringSpokenPresentationContext
    ) -> MindEyePresentationEligibilityDecision
}

nonisolated struct MindEyeDefaultPresentationEligibility:
    MindEyePresentationEligibilityChecking,
    Sendable
{
    static let explicitlyExcludedPrerecordingIDs: Set<String> = [
        "chapter02.room.rich.windowRecognition.001",
        "chapter02.room.rich.womanBattle.001",
        "prologue.rich.battle01.mrsDempsey.001",
        "chapter01.room.rich.dadFinalBattle.musicThirtySeconds.001",
        "chapter01.room.rich.dadFinalBattle.oneDamageRemaining.001",
        "chapter03.battle.biker.rich.001",
        "chapter03.battle.mike.recognition.001",
        "chapter03.battle.mike.surrender.002"
    ]

    private static let supportedSurfaces: Set<StoryInteractionSurfaceID> = [
        .walkie,
        .dadFrame,
        .crankRadio,
        .hamReceiver
    ]

    func decision(
        for context: TuringSpokenPresentationContext
    ) -> MindEyePresentationEligibilityDecision {
        guard Self.supportedSurfaces.contains(context.interactionSurface) else {
            return .suppressed(
                reason: "unsupportedSurface.\(context.interactionSurface.rawValue)"
            )
        }

        switch context.source {
        case .authored(let prerecordingID, let role):
            if Self.explicitlyExcludedPrerecordingIDs.contains(prerecordingID) {
                return .suppressed(
                    reason: "explicitlyExcludedPrerecording.\(prerecordingID)"
                )
            }
            switch role {
            case .primaryPrerecording, .authoredBridge:
                return .eligible
            case .openingCue, .closingBumper:
                return .suppressed(
                    reason: "nonPortraitAuthoredRole.\(role.rawValue)"
                )
            }
        case .generated:
            return .eligible
        }
    }
}
