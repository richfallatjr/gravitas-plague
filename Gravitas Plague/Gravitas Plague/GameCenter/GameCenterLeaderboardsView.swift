import GameKit
import SwiftUI

struct GameCenterLeaderboardsView: UIViewControllerRepresentable {
    func makeUIViewController(
        context: Context
    ) -> GKGameCenterViewController {
        let controller = GKGameCenterViewController(
            leaderboardID: PlagueGameCenterLeaderboardID.highestWaveReached,
            playerScope: .global,
            timeScope: .allTime
        )

        controller.gameCenterDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: GKGameCenterViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, GKGameCenterControllerDelegate {
        func gameCenterViewControllerDidFinish(
            _ gameCenterViewController: GKGameCenterViewController
        ) {
            gameCenterViewController.dismiss(
                animated: true
            )
        }
    }
}
