import Combine
import Foundation
import GameKit
import SwiftUI
import UIKit

enum PlagueGameCenterLeaderboardID {
    static let highestWaveReached =
        "com.gravitasplague.horde.highest_wave_reached"

    static let lifetimeWavesCleared =
        "com.gravitasplague.horde.lifetime_waves_cleared"
}

@MainActor
final class PlagueGameCenterManager: NSObject, ObservableObject {
    static let shared = PlagueGameCenterManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var lastErrorMessage: String?

    private override init() {
        super.init()
    }

    func authenticateIfNeeded() {
        let player = GKLocalPlayer.local

        player.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.lastErrorMessage = error.localizedDescription

                    print(
                        """
                        [GameCenter] authentication error
                          error: \(error.localizedDescription)
                        """
                    )
                }

                if let viewController {
                    self.presentAuthenticationController(viewController)
                    return
                }

                self.isAuthenticated = player.isAuthenticated

                print(
                    """
                    [GameCenter] authentication state
                      authenticated: \(player.isAuthenticated)
                      playerID: \(player.gamePlayerID)
                      displayName: \(player.displayName)
                    """
                )
            }
        }
    }

    private func presentAuthenticationController(
        _ viewController: UIViewController
    ) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            print("[GameCenter] ERROR could not find root controller for auth UI")
            return
        }

        root.present(
            viewController,
            animated: true
        )

        print("[GameCenter] presented authentication controller")
    }

    func submitHighestWaveReached(
        _ wave: Int
    ) {
        submitScore(
            wave,
            leaderboardID: PlagueGameCenterLeaderboardID.highestWaveReached,
            label: "highest_wave_reached"
        )
    }

    func submitLifetimeWavesCleared(
        _ waves: Int
    ) {
        submitScore(
            waves,
            leaderboardID: PlagueGameCenterLeaderboardID.lifetimeWavesCleared,
            label: "lifetime_waves_cleared"
        )
    }

    private func submitScore(
        _ score: Int,
        leaderboardID: String,
        label: String
    ) {
        guard GKLocalPlayer.local.isAuthenticated else {
            print(
                """
                [GameCenter] score not submitted; player not authenticated
                  label: \(label)
                  score: \(score)
                  leaderboardID: \(leaderboardID)
                """
            )
            return
        }

        GKLeaderboard.submitScore(
            score,
            context: 0,
            player: GKLocalPlayer.local,
            leaderboardIDs: [
                leaderboardID
            ]
        ) { error in
            Task { @MainActor in
                if let error {
                    self.lastErrorMessage = error.localizedDescription

                    print(
                        """
                        [GameCenter] submit score failed
                          label: \(label)
                          score: \(score)
                          leaderboardID: \(leaderboardID)
                          error: \(error.localizedDescription)
                        """
                    )
                } else {
                    print(
                        """
                        [GameCenter] submit score succeeded
                          label: \(label)
                          score: \(score)
                          leaderboardID: \(leaderboardID)
                        """
                    )
                }
            }
        }
    }
}
