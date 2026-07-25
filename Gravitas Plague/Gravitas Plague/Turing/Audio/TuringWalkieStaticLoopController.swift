import Foundation
import RealityKit

@MainActor
enum TuringStoryWalkieAudioRoute {
    private static var staticState: TuringWalkieStaticStateActor?
    private static var endpoint: TuringSpatialAudioEndpoint?

    static func install(
        audioController: GravitasDemoAudioController,
        walkieEmitter: Entity
    ) {
        _ = audioController
        let endpoint = TuringSpatialAudioEndpointFactory.make(
            emitter: walkieEmitter
        )
        self.endpoint = endpoint
        staticState = TuringWalkieStaticStateActor(endpoint: endpoint)

        print("""
        [TuringAudio] walkie emitter selected
          emitter: \(walkieEmitter.name)
          requiredEmitter: TuringStoryWalkieTalkie_AudioEmitter
          source: turing_story_wall_bundle_v1
        """)
    }

    static func clear(reason: String) {
        if let staticState {
            Task { await staticState.stopAll(reason: reason) }
        }
        if let endpoint {
            Task { await endpoint.stopAll(reason: reason) }
        }
        staticState = nil
        endpoint = nil
        print("""
        [TuringAudio] walkie emitter cleared
          reason: \(reason)
        """)
    }

    static func makeActiveEndpoint() -> TuringSpatialAudioEndpoint? {
        endpoint
    }

    static func startActiveRadioStaticLoop(
        fileURL: URL,
        reason: String
    ) async -> Bool {
        await startAmbientWalkieStaticLoop(
            fileURL: fileURL,
            reason: reason
        )
    }

    static func startAmbientWalkieStaticLoop(
        fileURL: URL,
        reason: String
    ) async -> Bool {
        guard let staticState else { return false }
        do {
            try await staticState.startAmbient(
                fileURL: fileURL,
                runID: reason
            )
            return true
        } catch {
            print("""
            [TuringRadioStaticLeadIn] walkie route failed
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
            return false
        }
    }

    static func retainAmbientWalkieStaticLoop(
        fileURL: URL,
        ownerID: String,
        reason: String
    ) async -> Bool {
        guard let staticState else { return false }
        do {
            try await staticState.retainAmbient(
                fileURL: fileURL,
                runID: reason,
                ownerID: ownerID
            )
            return true
        } catch {
            print("""
            [TuringWalkieStatic] retained walkie route failed
              ownerID: \(ownerID)
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
            return false
        }
    }

    static func stopActiveRadioStaticLoop(reason: String) async {
        await stopAmbientWalkieStaticLoop(reason: reason)
    }

    static func stopAmbientWalkieStaticLoop(reason: String) async {
        await staticState?.stopAmbient(reason: reason)
    }

    static func releaseAmbientWalkieStaticLoop(
        ownerID: String,
        reason: String
    ) async {
        await staticState?.releaseAmbient(
            ownerID: ownerID,
            reason: reason
        )
    }

    static func startSendingStaticLoop(
        fileURL: URL,
        reason: String
    ) async -> Bool {
        guard let staticState else { return false }
        do {
            try await staticState.startSending(
                fileURL: fileURL,
                runID: reason
            )
            return true
        } catch {
            print("""
            [TuringWalkieComms] sending static route failed
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
            return false
        }
    }

    static func stopSendingStaticLoop(reason: String) async {
        await staticState?.stopSending(reason: reason)
    }
}
