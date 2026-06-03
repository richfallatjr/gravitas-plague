import Combine
import RealityKit
import SwiftUI

struct PlagueImmersiveView: View {
    @ObservedObject var session: PlagueDemoSession
    @StateObject private var coordinator = PlagueImmersiveCoordinator()
    @StateObject private var damageTintController = DamageSurroundingsTintController()

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
        .preferredSurroundingsEffect(
            damageTintController.surroundingsEffect
        )
        .task(id: session.latestCommand?.id) {
            guard let commandEnvelope = session.latestCommand else { return }
            coordinator.handle(commandEnvelope)
        }
        .onReceive(frameTimer) { date in
            coordinator.tick(at: date)
        }
        .onAppear {
            coordinator.onPlayerDamaged = { amount in
                let intensity = min(max(Double(amount) / 50.0, 0.35), 1.0)
                session.triggerDamageTint(intensity: intensity)
            }
        }
        .onChange(of: session.damageTintEventID) { _, _ in
            damageTintController.trigger(
                intensity: session.damageTintIntensity
            )
        }
        .onDisappear {
            damageTintController.reset()
            coordinator.shutdown()
        }
    }
}
