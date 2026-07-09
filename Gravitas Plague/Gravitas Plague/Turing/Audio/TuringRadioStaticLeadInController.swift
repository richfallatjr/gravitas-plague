import Combine
import Foundation

@MainActor
final class TuringRadioStaticLeadInController: ObservableObject {
    @Published private(set) var isPlaying = false
    private var startTask: Task<Void, Never>?

    func start(reason: String) {
        guard isPlaying == false else {
            print("""
            [TuringRadioStaticLeadIn] already playing
              reason: \(reason)
            """)
            return
        }
        isPlaying = true
        startTask?.cancel()
        startTask = Task { @MainActor in
            print("""
            [TuringRadioStaticLeadIn] requesting ambient walkie static
              reason: \(reason)
              expected: walkie-talkie-static-loop.mp3
            """)
            await TuringWalkieCommsFXController.shared.startAmbientWalkieStatic(
                reason: "radioStaticLeadIn.\(reason)"
            )
        }
    }

    func stop(reason: String) {
        startTask?.cancel()
        startTask = nil
        guard isPlaying else { return }
        isPlaying = false
        Task { @MainActor in
            await TuringWalkieCommsFXController.shared.stopAmbientWalkieStatic(
                reason: "radioStaticLeadIn.\(reason)"
            )
        }
    }
}
