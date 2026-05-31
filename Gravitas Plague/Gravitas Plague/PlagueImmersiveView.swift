import Combine
import RealityKit
import SwiftUI

struct PlagueImmersiveView: View {
    @ObservedObject var session: PlagueDemoSession
    @StateObject private var coordinator = PlagueImmersiveCoordinator()

    private let frameTimer = Timer.publish(
        every: 1.0 / 60.0,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        RealityView { content in
            let sceneRoot = await coordinator.makeSceneRoot()
            content.add(sceneRoot)
        }
        .onReceive(frameTimer) { date in
            coordinator.tick(at: date)
        }
        .onChange(of: session.latestCommand?.id) { _, _ in
            guard let commandEnvelope = session.latestCommand else { return }
            coordinator.handle(commandEnvelope)
        }
        .onDisappear {
            coordinator.shutdown()
        }
    }
}
