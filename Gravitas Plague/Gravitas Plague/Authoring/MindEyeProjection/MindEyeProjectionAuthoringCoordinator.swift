#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Combine
import SwiftUI

@MainActor
final class MindEyeProjectionAuthoringCoordinator: ObservableObject {
    @Published private(set) var status = "Preparing Mind’s Eye projection authoring…"
    private var started = false

    func start(configuration: MindEyeProjectionAuthoringLaunchConfiguration) async {
        guard !started else { return }
        started = true
        do {
            try await MindEyeProjectionAuthoringJobRunner().run(
                MindEyeProjectionAuthoringJob(configuration: configuration)
            )
            status = "Mind’s Eye projection authoring complete."
        } catch {
            status = "Mind’s Eye projection authoring failed: \(error.localizedDescription)"
            print("[MindEyeProjectionAuthoring] FAIL \(error.localizedDescription)")
        }
    }
}

struct MindEyeProjectionAuthoringRootView: View {
    let configuration: MindEyeProjectionAuthoringLaunchConfiguration
    @StateObject private var coordinator = MindEyeProjectionAuthoringCoordinator()

    var body: some View {
        Text(coordinator.status)
            .font(.caption.monospaced())
            .padding(24)
            .task { await coordinator.start(configuration: configuration) }
    }
}
#endif
