import Combine
import Foundation

@MainActor
final class TuringRadioStaticLeadInController: ObservableObject {
    private enum ActiveRoute {
        case pendingWalkie
        case walkieQueuedStaticLane

        var logName: String {
            switch self {
            case .pendingWalkie:
                return "pendingWalkieQueuedStaticLane"
            case .walkieQueuedStaticLane:
                return "walkieQueuedStaticLane"
            }
        }
    }

    private var activeRoute: ActiveRoute?
    private var pendingStartTask: Task<Void, Never>?

    func start(reason: String) {
        if activeRoute != nil || pendingStartTask != nil {
            print("""
            [TuringRadioStaticLeadIn] already playing
              reason: \(reason)
              route: \(activeRoute?.logName ?? "pending")
            """)
            return
        }

        guard let url = Bundle.main.url(
            forResource: "Narrow-band-analog",
            withExtension: "wav"
        ) else {
            print("""
            [TuringRadioStaticLeadIn] missing static asset
              file: Narrow-band-analog.wav
              reason: \(reason)
            """)
            return
        }

        activeRoute = .pendingWalkie

        print("""
        [TuringRadioStaticLeadIn] waiting for walkie route
          reason: \(reason)
          file: \(url.lastPathComponent)
          fallbackToLocalPlayer: false
        """)

        pendingStartTask = Task { @MainActor [weak self] in
            await self?.startWhenWalkieRouteReady(
                fileURL: url,
                reason: reason
            )
        }
    }

    func stop(reason: String) {
        guard let activeRoute else {
            return
        }

        switch activeRoute {
        case .pendingWalkie:
            pendingStartTask?.cancel()
            pendingStartTask = nil
            print("""
            [TuringRadioStaticLeadIn] stopped
              reason: \(reason)
              route: pendingWalkieQueuedStaticLane
            """)
        case .walkieQueuedStaticLane:
            Task { @MainActor in
                await TuringStoryWalkieAudioRoute.stopActiveRadioStaticLoop(
                    reason: reason
                )
            }
        }

        self.activeRoute = nil
    }

    private func startWhenWalkieRouteReady(
        fileURL: URL,
        reason: String
    ) async {
        let deadline = Date().addingTimeInterval(12.0)
        var attempt = 0

        while Date() < deadline {
            guard Task.isCancelled == false else {
                return
            }

            attempt += 1
            if await TuringStoryWalkieAudioRoute.startActiveRadioStaticLoop(
                fileURL: fileURL,
                reason: reason
            ) {
                activeRoute = .walkieQueuedStaticLane
                pendingStartTask = nil
                print("""
                [TuringRadioStaticLeadIn] walkie route resolved
                  reason: \(reason)
                  attempts: \(attempt)
                  route: walkieQueuedStaticLane
                  lane: TuringWalkieAudio_StaticLane
                  fallbackToLocalPlayer: false
                """)
                return
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        pendingStartTask = nil
        activeRoute = nil

        print("""
        [TuringRadioStaticLeadIn] start failed
          reason: \(reason)
          route: walkieQueuedStaticLane
          fallbackToLocalPlayer: false
          error: timed out waiting for TuringStoryWalkieTalkie_AudioEmitter
        """)
    }
}
