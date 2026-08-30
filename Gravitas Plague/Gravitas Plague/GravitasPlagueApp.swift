import SwiftUI
import TuringQwenNative

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
#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
    private let projectionAuthoringConfiguration:
        MindEyeProjectionAuthoringLaunchConfiguration?
    private let isUnitTestLaunch: Bool
#endif

    init() {
#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
        isUnitTestLaunch =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        do {
            projectionAuthoringConfiguration = try
                MindEyeProjectionAuthoringLaunchConfiguration.current()
        } catch {
            preconditionFailure(
                "Mind's Eye projection authoring launch configuration failed: " +
                    error.localizedDescription
            )
        }
        if projectionAuthoringConfiguration != nil || isUnitTestLaunch {
            return
        }
#endif
        do {
            try TuringMLXCommandBufferStartup.configure()
        } catch {
            preconditionFailure(
                "Turing MLX command-buffer startup configuration failed: \(error.localizedDescription)"
            )
        }
        MindEyeRuntimeRegistration.registerOnce()
        TuringProductionDiagnostics.start()
        TuringMemoryBudgetProbe.log(label: "appLaunch")
    }

    var body: some Scene {
        WindowGroup(id: PlagueWindowID.control) {
#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
            if isUnitTestLaunch {
                Color.clear
            } else if let projectionAuthoringConfiguration {
                MindEyeProjectionAuthoringRootView(
                    configuration: projectionAuthoringConfiguration
                )
            } else {
                PlagueDemoView(session: demoSession)
                    .frame(
                        width: OperationModePosterLayout.swiftUIWindowWidth,
                        height: OperationModePosterLayout.swiftUIWindowHeight
                    )
            }
#else
            PlagueDemoView(session: demoSession)
                .frame(
                    width: OperationModePosterLayout.swiftUIWindowWidth,
                    height: OperationModePosterLayout.swiftUIWindowHeight
                )
#endif
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
