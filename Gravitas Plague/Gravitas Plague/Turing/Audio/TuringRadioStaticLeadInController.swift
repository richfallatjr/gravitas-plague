import AVFoundation
import Combine
import Foundation

@MainActor
final class TuringRadioStaticLeadInController: ObservableObject {
    private enum ActiveRoute {
        case walkieSpatial
        case localPlayer

        var logName: String {
            switch self {
            case .walkieSpatial:
                return "walkieSpatial"
            case .localPlayer:
                return "localPlayerFallback"
            }
        }
    }

    private var player: AVAudioPlayer?
    private var activeRoute: ActiveRoute?

    func start(reason: String) {
        if activeRoute != nil || player?.isPlaying == true {
            print("""
            [TuringRadioStaticLeadIn] already playing
              reason: \(reason)
              route: \(activeRoute?.logName ?? "localPlayer")
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

        if TuringStoryWalkieAudioRoute.startActiveRadioStaticLoop(
            fileURL: url,
            reason: reason
        ) {
            activeRoute = .walkieSpatial
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.20
            player.prepareToPlay()
            player.play()
            self.player = player
            activeRoute = .localPlayer
            print("""
            [TuringRadioStaticLeadIn] started
              reason: \(reason)
              file: \(url.lastPathComponent)
              route: localPlayerFallback
            """)
        } catch {
            print("""
            [TuringRadioStaticLeadIn] start failed
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
        }
    }

    func stop(reason: String) {
        guard let activeRoute else {
            return
        }

        switch activeRoute {
        case .walkieSpatial:
            TuringStoryWalkieAudioRoute.stopActiveRadioStaticLoop(
                reason: reason
            )
        case .localPlayer:
            player?.stop()
            player?.currentTime = 0
            player = nil
            print("""
            [TuringRadioStaticLeadIn] stopped
              reason: \(reason)
              route: localPlayerFallback
            """)
        }

        self.activeRoute = nil
    }
}
