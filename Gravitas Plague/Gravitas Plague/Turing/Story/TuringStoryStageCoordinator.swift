import Combine
import Foundation

@MainActor
final class TuringStoryStageCoordinator: ObservableObject {
    static let shared = TuringStoryStageCoordinator()

    enum State: Equatable {
        case unavailable
        case preparing(generation: Int)
        case established(generation: Int)
        case failed(message: String)
    }

    @Published private(set) var state: State = .unavailable
    private(set) var generation = 0

    var isEstablished: Bool {
        if case .established = state { return true }
        return false
    }

    @discardableResult
    func beginPreparation(reason: String) -> Int {
        if case .established(let generation) = state {
            return generation
        }
        if case .preparing(let generation) = state {
            return generation
        }
        generation += 1
        state = .preparing(generation: generation)
        print("[TuringStoryStage] preparation began generation=\(generation) reason=\(reason)")
        return generation
    }

    func markEstablished(generation: Int) {
        guard generation == self.generation else { return }
        state = .established(generation: generation)
        print("[TuringStoryStage] established generation=\(generation)")
    }

    func markFailed(generation: Int, error: Error) {
        guard generation == self.generation else { return }
        state = .failed(message: error.localizedDescription)
        print("[TuringStoryStage] failed generation=\(generation) error=\(error.localizedDescription)")
    }

    func invalidate(reason: String) {
        generation += 1
        state = .unavailable
        print("[TuringStoryStage] invalidated reason=\(reason)")
    }
}
