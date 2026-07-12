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
        publish(
            reason:
                "conversationCompleted.\(conversationRunID.uuidString)"
        )
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
