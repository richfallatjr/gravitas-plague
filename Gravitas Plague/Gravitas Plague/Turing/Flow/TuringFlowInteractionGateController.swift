import Combine
import Foundation

extension Notification.Name {
    static let turingFlowInteractionGateChanged =
        Notification.Name("turingFlowInteractionGateChanged")
}

@MainActor
final class TuringFlowInteractionGateController: ObservableObject {
    static let shared = TuringFlowInteractionGateController()

    enum State: String, Sendable {
        case closed
        case microphone
        case play
        case busy
    }

    @Published private(set) var state: State = .closed
    @Published private(set) var dadFrameState: State = .closed

    private var ownerBySurface:
        [StoryInteractionSurfaceID: UUID] = [:]

    var microphoneEnabled: Bool {
        state == .microphone
    }

    var playEnabled: Bool {
        state == .play
    }

    private init() {}

    func state(for surfaceID: StoryInteractionSurfaceID) -> State {
        switch surfaceID {
        case .walkie:
            return state
        case .dadFrame:
            return dadFrameState
        }
    }

    func armPlay(reason: String) {
        armPlay(surfaceID: .walkie, reason: reason)
    }

    func armPlay(
        surfaceID: StoryInteractionSurfaceID,
        reason: String
    ) {
        guard state(for: surfaceID) == .closed else {
            print("""
            [TuringFlowGate] play arm ignored
              surface: \(surfaceID.rawValue)
              state: \(state(for: surfaceID).rawValue)
              reason: \(reason)
            """)
            return
        }
        ownerBySurface[surfaceID] = nil
        setRaw(
            .play,
            surfaceID: surfaceID,
            reason: "playArmed.\(reason)"
        )
    }

    func forcePlayForStoryTeleport(reason: String) {
        precondition(ownerBySurface[.walkie] == nil)
        setRaw(
            .play,
            surfaceID: .walkie,
            reason: "storyTeleportPlay.\(reason)"
        )
    }

    func forceMicrophoneForStoryTeleport(reason: String) {
        precondition(ownerBySurface[.walkie] == nil)
        setRaw(
            .microphone,
            surfaceID: .walkie,
            reason: "storyTeleportMicrophone.\(reason)"
        )
    }

    func forceClosedForStoryTeleport(reason: String) {
        ownerBySurface[.walkie] = nil
        setRaw(
            .closed,
            surfaceID: .walkie,
            reason: "storyTeleportHidden.\(reason)"
        )
    }

    func claimPlay(reason: String) -> Bool {
        claimPlay(surfaceID: .walkie, reason: reason)
    }

    func claimPlay(
        surfaceID: StoryInteractionSurfaceID,
        reason: String
    ) -> Bool {
        guard state(for: surfaceID) == .play else {
            return false
        }
        ownerBySurface[surfaceID] = nil
        setRaw(
            .busy,
            surfaceID: surfaceID,
            reason: "playClaimed.\(reason)"
        )
        return true
    }

    func restorePlayAfterFailedClaim(reason: String) {
        restorePlayAfterFailedClaim(
            surfaceID: .walkie,
            reason: reason
        )
    }

    func restorePlayAfterFailedClaim(
        surfaceID: StoryInteractionSurfaceID,
        reason: String
    ) {
        guard state(for: surfaceID) == .busy,
              ownerBySurface[surfaceID] == nil else {
            return
        }
        setRaw(
            .play,
            surfaceID: surfaceID,
            reason: "playClaimFailed.\(reason)"
        )
    }

    func beginFlow(identity: TuringFlowIdentity) {
        let surfaceID = identity.interactionSurface
        ownerBySurface[surfaceID] = identity.flowInstanceID
        set(
            .busy,
            identity: identity,
            reason: "pointStarted"
        )
    }

    func applyCompletionGate(
        _ gate: TuringFlowDescriptor.Progression.InteractionGate,
        identity: TuringFlowIdentity
    ) {
        let surfaceID = identity.interactionSurface
        guard ownerBySurface[surfaceID] == identity.flowInstanceID else {
            print("""
            [TuringFlowGate] stale completion ignored
              surface: \(surfaceID.rawValue)
              flowInstanceID: \(identity.flowInstanceID.uuidString)
              ownerFlowInstanceID: \(ownerBySurface[surfaceID]?.uuidString ?? "none")
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
        set(next, identity: identity, reason: "pointCompleted")
    }

    func beginConversation(conversationRunID: UUID) {
        beginConversation(
            conversationRunID: conversationRunID,
            surfaceID: .walkie
        )
    }

    func beginConversation(
        conversationRunID: UUID,
        surfaceID: StoryInteractionSurfaceID
    ) {
        ownerBySurface[surfaceID] = conversationRunID
        setRaw(
            .busy,
            surfaceID: surfaceID,
            reason: "conversationStarted.\(conversationRunID.uuidString)"
        )
    }

    func restoreMicrophoneAfterConversation(
        conversationRunID: UUID
    ) {
        restoreMicrophoneAfterConversation(
            conversationRunID: conversationRunID,
            surfaceID: .walkie
        )
    }

    func restoreMicrophoneAfterConversation(
        conversationRunID: UUID,
        surfaceID: StoryInteractionSurfaceID
    ) {
        ownerBySurface[surfaceID] = nil
        setRaw(
            .microphone,
            surfaceID: surfaceID,
            reason: "conversationCompleted.\(conversationRunID.uuidString)"
        )
    }

    func restoreMicrophoneAfterProgressionFailure(
        conversationRunID: UUID,
        reason: String
    ) {
        restoreMicrophoneAfterProgressionFailure(
            conversationRunID: conversationRunID,
            surfaceID: .walkie,
            reason: reason
        )
    }

    func restoreMicrophoneAfterProgressionFailure(
        conversationRunID: UUID,
        surfaceID: StoryInteractionSurfaceID,
        reason: String
    ) {
        ownerBySurface[surfaceID] = nil
        setRaw(
            .microphone,
            surfaceID: surfaceID,
            reason: "progressionFailed.\(conversationRunID.uuidString).\(reason)"
        )
    }

    func ensureMicrophoneAvailable(reason: String) {
        ensureMicrophoneAvailable(
            surfaceID: .walkie,
            reason: reason
        )
    }

    func ensureMicrophoneAvailable(
        surfaceID: StoryInteractionSurfaceID,
        reason: String
    ) {
        let previous = state(for: surfaceID)
        ownerBySurface[surfaceID] = nil
        setRaw(
            .microphone,
            surfaceID: surfaceID,
            reason: reason
        )
        print("""
        [TuringFlowGate] terminal microphone verified
          surface: \(surfaceID.rawValue)
          previousState: \(previous.rawValue)
          state: \(state(for: surfaceID).rawValue)
          repaired: \(previous != .microphone)
          reason: \(reason)
        """)
    }

    func closeForScheduledProgression(reason: String) {
        ownerBySurface[.walkie] = nil
        setRaw(
            .closed,
            surfaceID: .walkie,
            reason: reason
        )
    }

    func failFlow(identity: TuringFlowIdentity, reason: String) {
        let surfaceID = identity.interactionSurface
        guard ownerBySurface[surfaceID] == identity.flowInstanceID else {
            return
        }
        ownerBySurface[surfaceID] = nil
        setRaw(
            .closed,
            surfaceID: surfaceID,
            reason: "flowFailed.\(reason)"
        )
    }

    func reset(reason: String) {
        ownerBySurface.removeAll(keepingCapacity: false)
        state = .closed
        dadFrameState = .closed
        publish(surfaceID: .walkie, reason: "reset.\(reason)")
        publish(surfaceID: .dadFrame, reason: "reset.\(reason)")
    }

    private func set(
        _ newState: State,
        identity: TuringFlowIdentity,
        reason: String
    ) {
        let surfaceID = identity.interactionSurface
        if newState != .busy {
            ownerBySurface[surfaceID] = nil
        }
        setRaw(newState, surfaceID: surfaceID, reason: reason)
        print("""
        [TuringFlowGate] changed
          flowInstanceID: \(identity.flowInstanceID.uuidString)
          scriptPointID: \(identity.scriptPointID)
          surface: \(surfaceID.rawValue)
          state: \(newState.rawValue)
          reason: \(reason)
        """)
    }

    private func setRaw(
        _ newState: State,
        surfaceID: StoryInteractionSurfaceID,
        reason: String
    ) {
        switch surfaceID {
        case .walkie:
            state = newState
        case .dadFrame:
            dadFrameState = newState
        }
        publish(surfaceID: surfaceID, reason: reason)
    }

    private func publish(
        surfaceID: StoryInteractionSurfaceID,
        reason: String
    ) {
        let surfaceState = state(for: surfaceID)
        NotificationCenter.default.post(
            name: .turingFlowInteractionGateChanged,
            object: self,
            userInfo: [
                "surface": surfaceID.rawValue,
                "state": surfaceState.rawValue,
                "reason": reason
            ]
        )

        let mapped: StoryTuringGateState
        switch surfaceState {
        case .closed:
            mapped = .closed
        case .play:
            mapped = .play
        case .busy:
            mapped = .busy
        case .microphone:
            mapped = .microphone
        }

        Task {
            await StoryInteractionArbiter.shared.updateTuringGate(
                mapped,
                surfaceID: surfaceID,
                reason: reason
            )
        }
    }
}
