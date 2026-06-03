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
        ZStack {
            RealityView { content in
                let sceneRoot = await coordinator.makeSceneRoot()
                content.add(sceneRoot)
            }
            .task(id: session.latestCommand?.id) {
                guard let commandEnvelope = session.latestCommand else { return }
                coordinator.handle(commandEnvelope)
            }
            .onReceive(frameTimer) { date in
                coordinator.tick(at: date)
            }
            .onDisappear {
                coordinator.shutdown()
            }

            DamageFlashOverlay(
                token: session.damageFlashToken,
                intensity: session.damageFlashIntensity
            )
        }
        .onAppear {
            coordinator.onPlayerDamaged = { amount in
                let intensity = min(Float(amount) / 50.0, 1.0)
                session.triggerDamageFlash(intensity: intensity)
            }
        }
    }
}
