import Foundation
import RealityKit

@MainActor
final class HordePortalAudioController {
    let portalID: UUID

    private let emitter = Entity()
    private weak var audioController: GravitasDemoAudioController?
    private var loopController: AudioPlaybackController?

    init(
        portalID: UUID,
        audioController: GravitasDemoAudioController
    ) {
        self.portalID = portalID
        self.audioController = audioController

        emitter.name = "HordePortalAudioEmitter_\(portalID.uuidString.prefix(8))"
    }

    @discardableResult
    func attachAndStart(
        portalRoot: Entity
    ) -> Bool {
        guard HordePortalAudioSettings.mixdownURL() != nil else {
            print(
                """
                [HordePortalAudio] ERROR cannot start portal loop; asset missing
                  portalID: \(portalID)
                  file: \(HordePortalAudioSettings.mixdownName).\(HordePortalAudioSettings.mixdownExtension)
                  fallback: false
                """
            )
            return false
        }

        guard let audioController else {
            print(
                """
                [HordePortalAudio] ERROR cannot start portal loop; audio controller missing
                  portalID: \(portalID)
                  fallback: false
                """
            )
            return false
        }

        if emitter.parent == nil {
            portalRoot.addChild(emitter)
        }

        emitter.position = HordePortalAudioSettings.localEmitterOffset

        let label = "\(HordePortalAudioSettings.labelPrefix)_\(portalID.uuidString)"

        loopController = audioController.attachSpatialLoop(
            named: HordePortalAudioSettings.mixdownName,
            fileExtension: HordePortalAudioSettings.mixdownExtension,
            to: emitter,
            volumeDB: HordePortalAudioSettings.portalLoopGainDB,
            label: label
        )

        guard loopController != nil else {
            print(
                """
                [HordePortalAudio] ERROR portal loop failed to start
                  portalID: \(portalID)
                  file: \(HordePortalAudioSettings.mixdownName).\(HordePortalAudioSettings.mixdownExtension)
                  fallback: false
                """
            )
            return false
        }

        print(
            """
            [HordePortalAudio] portal loop started
              portalID: \(portalID)
              file: \(HordePortalAudioSettings.mixdownName).\(HordePortalAudioSettings.mixdownExtension)
              gainDB: \(HordePortalAudioSettings.portalLoopGainDB)
              emitterLocalOffset: \(HordePortalAudioSettings.localEmitterOffset)
              spatial: true
              loop: true
            """
        )

        return true
    }

    func updateGainDB(
        _ gainDB: Float
    ) {
        guard let loopController else {
            return
        }

        audioController?.setLoopGainDB(
            loopController,
            gainDB: gainDB
        )

        print(
            """
            [HordePortalAudio] portal loop gain updated
              portalID: \(portalID)
              gainDB: \(gainDB)
            """
        )
    }

    func stop() {
        if let loopController {
            audioController?.stopLoop(loopController)
            self.loopController = nil
        }

        emitter.removeFromParent()

        print(
            """
            [HordePortalAudio] portal loop stopped
              portalID: \(portalID)
            """
        )
    }
}
