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
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let fileURL = Self.staticURL() else {
                print("""
                [TuringRadioStaticLeadIn] missing static asset
                  reason: \(reason)
                  expected: Narrow-band-analog.wav
                """)
                return
            }
            let routed = await TuringStoryWalkieAudioRoute
                .startActiveRadioStaticLoop(fileURL: fileURL, reason: reason)
            if routed == false {
                print("""
                [TuringRadioStaticLeadIn] waiting for walkie route
                  reason: \(reason)
                  expectedEmitter: TuringStoryWalkieTalkie_AudioEmitter
                """)
            }
        }
    }

    func stop(reason: String) {
        startTask?.cancel()
        startTask = nil
        guard isPlaying else { return }
        isPlaying = false
        Task { @MainActor in
            await TuringStoryWalkieAudioRoute.stopActiveRadioStaticLoop(
                reason: reason
            )
        }
    }

    private static func staticURL() -> URL? {
        Bundle.main.url(
            forResource: "Narrow-band-analog",
            withExtension: "wav"
        ) ?? Bundle.main.url(
            forResource: "Narrow-band-analog",
            withExtension: "wav",
            subdirectory: "Audio"
        )
    }
}
