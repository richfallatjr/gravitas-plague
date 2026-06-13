import SwiftUI

enum PlagueWindowID {
    static let control = "plague-control"
    static let leaderboards = "plague-leaderboards"
}

@main
struct GravitasPlagueApp: App {
    @StateObject private var demoSession = PlagueDemoSession()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup(id: PlagueWindowID.control) {
            PlagueDemoView(session: demoSession)
                .frame(minWidth: 543, minHeight: 724)
        }
        .defaultSize(width: 815, height: 1086)
        .defaultLaunchBehavior(.automatic)
        .restorationBehavior(.disabled)

        WindowGroup(id: PlagueWindowID.leaderboards) {
            GameCenterLeaderboardsView()
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        ImmersiveSpace(id: PlagueDemoSession.immersiveSpaceID) {
            PlagueImmersiveView(session: demoSession)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
