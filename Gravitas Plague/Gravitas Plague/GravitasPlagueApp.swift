import SwiftUI

enum PlagueWindowID {
    static let control = "plague-control"
    static let storyEpisodes = "plague-story-episodes"
    static let storyDebug = "plague-story-debug"
    static let leaderboards = "plague-leaderboards"
}

@main
struct GravitasPlagueApp: App {
    @StateObject private var demoSession = PlagueDemoSession()
    @State private var immersionStyle: ImmersionStyle = .mixed

    init() {
        TuringProductionDiagnostics.start()
        TuringMemoryBudgetProbe.log(label: "appLaunch")
    }

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

        WindowGroup(id: PlagueWindowID.storyEpisodes) {
            TuringStoryEpisodePickerView(session: demoSession)
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

#if DEBUG || GR_TURING_DIAGNOSTICS
        WindowGroup(id: PlagueWindowID.storyDebug) {
            TuringEpisodePickerView(session: demoSession)
                .frame(minWidth: 520)
        }
        .defaultSize(width: 560, height: 760)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
#endif

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
