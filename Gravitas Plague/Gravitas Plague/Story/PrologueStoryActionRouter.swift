import Foundation

@MainActor
final class PrologueStoryActionRouter: TuringScriptPointCompletionEventSink {
    private let battle01: Battle01Coordinator
    private var handledEventIDs = Set<UUID>()
    private var battle01Triggered = false

    init(battle01: Battle01Coordinator) {
        self.battle01 = battle01
    }

    func scriptPointCompleted(_ event: TuringScriptPointCompletionEvent) {
        guard event.scriptPointID == "prologue.scriptPoint03",
              handledEventIDs.insert(event.eventID).inserted,
              battle01Triggered == false else {
            return
        }
        battle01Triggered = true
        battle01.start(trigger: .scriptPointCompleted(event))
    }

    func reset(reason: String) {
        handledEventIDs.removeAll(keepingCapacity: false)
        battle01Triggered = false
        print("[Battle01] Prologue action router reset reason=\(reason)")
    }
}
