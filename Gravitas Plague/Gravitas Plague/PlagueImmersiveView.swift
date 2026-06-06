import Combine
import RealityKit
import SwiftUI

struct PlagueImmersiveView: View {
    @ObservedObject var session: PlagueDemoSession
    @StateObject private var coordinator = PlagueImmersiveCoordinator()
    @StateObject private var damageTintController = DamageSurroundingsTintController()
    @StateObject private var deathPresentationController = DeathPresentationController()

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
            deathPresentationController.surroundingsEffect
                ?? damageTintController.surroundingsEffect
        )
        .task(id: session.latestCommand?.id) {
            guard let commandEnvelope = session.latestCommand else { return }
            coordinator.handle(commandEnvelope)
        }
        .onReceive(frameTimer) { date in
            coordinator.tick(at: date)
        }
        .onAppear {
            coordinator.deathPresentationController = deathPresentationController
            coordinator.onPlayerDamaged = { amount in
                let intensity = min(max(Double(amount) / 50.0, 0.35), 1.0)
                session.triggerDamageTint(intensity: intensity)
            }
            coordinator.onPlayerDeathStarted = {
                damageTintController.reset()
            }
        }
        .onChange(of: session.damageTintEventID) { _, _ in
            damageTintController.trigger(
                intensity: session.damageTintIntensity
            )
        }
        .onDisappear {
            damageTintController.reset()
            deathPresentationController.reset()
            coordinator.shutdown()
        }
    }
}
