import Foundation
import RealityKit

@MainActor
enum TuringRichHeadsetAudioRoute {
    private static var emitter: Entity?
    private static var endpoint: TuringSpatialAudioEndpoint?

    static func install(on headAnchor: Entity) {
        clear(reason: "replaceHeadAnchor")

        let emitter = Entity()
        emitter.name = "TuringRichHeadset_AudioEmitter"
        emitter.position = SIMD3<Float>(0, -0.05, -0.10)
        emitter.components.set(SpatialAudioComponent())
        headAnchor.addChild(emitter)

        self.emitter = emitter
        endpoint = TuringSpatialAudioEndpointFactory.make(emitter: emitter)

        print("""
        [TuringAudio] Rich headset emitter installed
          emitter: TuringRichHeadset_AudioEmitter
          parent: \(headAnchor.name)
          route: headTrackedSpatial
          localPosition: \(emitter.position)
        """)
    }

    static func makeActiveEndpoint() -> TuringSpatialAudioEndpoint? {
        endpoint
    }

    static func clear(reason: String) {
        if let endpoint {
            Task { await endpoint.stopAll(reason: reason) }
        }
        endpoint = nil
        emitter?.removeFromParent()
        emitter = nil
    }
}
