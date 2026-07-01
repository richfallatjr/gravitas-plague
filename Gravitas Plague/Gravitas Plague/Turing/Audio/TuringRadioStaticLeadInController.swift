import AVFoundation
import Combine
import Foundation

@MainActor
final class TuringRadioStaticLeadInController: ObservableObject {
    private var player: AVAudioPlayer?

    func start(reason: String) {
        if player?.isPlaying == true {
            print("""
            [TuringRadioStaticLeadIn] already playing
              reason: \(reason)
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

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.20
            player.prepareToPlay()
            player.play()
            self.player = player
            print("""
            [TuringRadioStaticLeadIn] started
              reason: \(reason)
              file: \(url.lastPathComponent)
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
        guard let player else {
            return
        }

        player.stop()
        player.currentTime = 0
        self.player = nil

        print("""
        [TuringRadioStaticLeadIn] stopped
          reason: \(reason)
        """)
    }
}
