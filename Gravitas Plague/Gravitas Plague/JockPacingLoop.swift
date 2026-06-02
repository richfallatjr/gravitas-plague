import Foundation

struct JockPacingLoopStep: Equatable {
    let clipID: String
    let loopClip: Bool

    static let gravitasPresenceLoop: [JockPacingLoopStep] = [
        JockPacingLoopStep(
            clipID: "idle_01",
            loopClip: false
        ),
        JockPacingLoopStep(
            clipID: "turn_right_90",
            loopClip: false
        ),
        JockPacingLoopStep(
            clipID: "turn_right_90",
            loopClip: false
        ),
        JockPacingLoopStep(
            clipID: "unstable_walk_01",
            loopClip: false
        )
    ]

    static let turn360Test: [JockPacingLoopStep] = [
        JockPacingLoopStep(
            clipID: "turn_right_90",
            loopClip: false
        ),
        JockPacingLoopStep(
            clipID: "turn_right_90",
            loopClip: false
        ),
        JockPacingLoopStep(
            clipID: "turn_right_90",
            loopClip: false
        ),
        JockPacingLoopStep(
            clipID: "turn_right_90",
            loopClip: false
        )
    ]
}
