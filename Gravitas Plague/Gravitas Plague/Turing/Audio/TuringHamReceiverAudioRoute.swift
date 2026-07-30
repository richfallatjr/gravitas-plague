import RealityKit

@MainActor
enum TuringHamReceiverAudioRoute {
    private static weak var emitter: Entity?
    private static var endpoint: TuringSpatialAudioEndpoint?

    static func install(on emitter: Entity) {
        clear(reason: "replaceHamReceiverEmitter")
        self.emitter = emitter
        endpoint = TuringSpatialAudioEndpointFactory.make(
            emitter: emitter
        )
        print("""
        [TuringHamReceiverRoute] installed
          emitter: \(emitter.name)
        """)
    }

    static func requireActiveEndpoint() throws
        -> TuringSpatialAudioEndpoint
    {
        guard let emitter,
              emitter.parent != nil,
              let endpoint else {
            throw TuringRuntimeError.invalidConfig(
                "Ham-receiver spatial endpoint is not installed."
            )
        }
        return endpoint
    }

    static func clear(reason: String) {
        if let endpoint {
            Task {
                await endpoint.stopAll(reason: reason)
            }
        }
        endpoint = nil
        emitter = nil
        print("""
        [TuringHamReceiverRoute] cleared
          reason: \(reason)
        """)
    }
}
