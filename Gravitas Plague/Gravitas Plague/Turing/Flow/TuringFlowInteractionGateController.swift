import Combine
import Foundation

extension Notification.Name {
    static let turingFlowInteractionGateChanged =
        Notification.Name("turingFlowInteractionGateChanged")
}

@MainActor
final class TuringFlowInteractionGateController:
    ObservableObject
{
    static let shared =
        TuringFlowInteractionGateController()

    enum State: String, Sendable {
        case closed
        case microphone
        case play
        case busy
    }

    @Published private(set) var state:
        State = .closed

    private var ownerFlowInstanceID: UUID?

    var microphoneEnabled: Bool {
        state == .microphone
    }

    var playEnabled: Bool {
        state == .play
    }

    private init() {}

    func armPlay(reason: String) {
        guard state == .closed else {
            print("""
            [TuringFlowGate] play arm ignored
              state: \(state.rawValue)
              reason: \(reason)
            """)
            return
        }

        state = .play
        ownerFlowInstanceID = nil
        publish(reason: "playArmed.\(reason)")
    }

    func claimPlay(reason: String) -> Bool {
        guard state == .play else {
            print("""
            [TuringFlowGate] play claim ignored
              state: \(state.rawValue)
              reason: \(reason)
            """)
            return false
        }

        state = .busy
        ownerFlowInstanceID = nil
        publish(reason: "playClaimed.\(reason)")
        return true
    }

    func restorePlayAfterFailedClaim(reason: String) {
        guard state == .busy,
              ownerFlowInstanceID == nil else {
            return
        }

        state = .play
        publish(reason: "playClaimFailed.\(reason)")
    }

    func beginFlow(
        identity: TuringFlowIdentity
    ) {
        ownerFlowInstanceID =
            identity.flowInstanceID
        set(
            .busy,
            identity: identity,
            reason: "pointStarted"
        )
    }

    func applyCompletionGate(
        _ gate:
            TuringFlowDescriptor.Progression
            .InteractionGate,
        identity: TuringFlowIdentity
    ) {
        guard ownerFlowInstanceID ==
                identity.flowInstanceID else {
            print("""
            [TuringFlowGate] stale completion ignored
              flowInstanceID: \(identity.flowInstanceID.uuidString)
              ownerFlowInstanceID: \(ownerFlowInstanceID?.uuidString ?? "none")
            """)
            return
        }

        let next: State
        switch gate {
        case .closed:
            next = .closed
        case .microphone:
            next = .microphone
        case .play:
            next = .play
        }

        set(
            next,
            identity: identity,
            reason: "pointCompleted"
        )
    }

    func beginConversation(
        conversationRunID: UUID
    ) {
        state = .busy
        publish(
            reason:
                "conversationStarted.\(conversationRunID.uuidString)"
        )
    }

    func restoreMicrophoneAfterConversation(
        conversationRunID: UUID
    ) {
        state = .microphone
        ownerFlowInstanceID = nil
        publish(
            reason:
                "conversationCompleted.\(conversationRunID.uuidString)"
        )
    }

    func restoreMicrophoneAfterProgressionFailure(
        conversationRunID: UUID,
        reason: String
    ) {
        state = .microphone
        ownerFlowInstanceID = nil
        publish(
            reason:
                "progressionFailed.\(conversationRunID.uuidString).\(reason)"
        )

        print("""
        [TuringFlowGate] microphone recovered after progression failure
          conversationRunID: \(conversationRunID.uuidString)
          state: \(state.rawValue)
          reason: \(reason)
        """)
    }

    func ensureMicrophoneAvailable(reason: String) {
        let previousState = state
        state = .microphone
        ownerFlowInstanceID = nil
        publish(reason: reason)

        print("""
        [TuringFlowGate] terminal microphone verified
          previousState: \(previousState.rawValue)
          state: \(state.rawValue)
          repaired: \(previousState != .microphone)
          reason: \(reason)
        """)
    }

    func closeForScheduledProgression(
        reason: String
    ) {
        state = .closed
        ownerFlowInstanceID = nil
        publish(reason: reason)
    }

    func failFlow(
        identity: TuringFlowIdentity,
        reason: String
    ) {
        guard ownerFlowInstanceID ==
                identity.flowInstanceID else {
            return
        }
        state = .closed
        ownerFlowInstanceID = nil
        publish(reason: "flowFailed.\(reason)")
    }

    func reset(reason: String) {
        state = .closed
        ownerFlowInstanceID = nil
        publish(reason: "reset.\(reason)")
    }

    private func set(
        _ newState: State,
        identity: TuringFlowIdentity,
        reason: String
    ) {
        state = newState
        if newState != .busy {
            ownerFlowInstanceID = nil
        }

        print("""
        [TuringFlowGate] changed
          flowInstanceID: \(identity.flowInstanceID.uuidString)
          scriptPointID: \(identity.scriptPointID)
          state: \(newState.rawValue)
          reason: \(reason)
        """)
        publish(reason: reason)
    }

    private func publish(reason: String) {
        NotificationCenter.default.post(
            name: .turingFlowInteractionGateChanged,
            object: self,
            userInfo: [
                "state": state.rawValue,
                "reason": reason
            ]
        )
    }
}
