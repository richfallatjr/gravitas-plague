import Foundation

@MainActor
final class Chapter01DadBattleDamageClock {
    private weak var music: Chapter01DadBattleMusicController?
    private var epoch: Chapter01DadBattleMusicEpoch?

    func arm(
        music: Chapter01DadBattleMusicController,
        epoch: Chapter01DadBattleMusicEpoch
    ) {
        self.music = music
        self.epoch = epoch
    }

    var currentMediaTime: TimeInterval? {
        guard let music, let epoch else { return nil }
        return music.mediaTimeSeconds(for: epoch)
    }

    func reset() {
        music = nil
        epoch = nil
    }
}
