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
                .frame(
                    width: OperationModePosterLayout.swiftUIWindowWidth,
                    height: OperationModePosterLayout.swiftUIWindowHeight
                )
        }
        .defaultSize(
            width: OperationModePosterLayout.swiftUIWindowWidth,
            height: OperationModePosterLayout.swiftUIWindowHeight
        )
        .windowResizability(.contentSize)
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
