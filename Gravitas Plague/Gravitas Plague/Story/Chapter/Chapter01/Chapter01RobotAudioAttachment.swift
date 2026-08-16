import Foundation
import RealityKit

@MainActor
protocol Chapter01RobotAudioAttachment: AnyObject {
    var enemyID: UUID { get }
    var isActive: Bool { get }

    func deactivate(reason: String) async
}

@MainActor
final class Chapter01RobotAudioAttachmentLease: Chapter01RobotAudioAttachment {
    let enemyID: UUID

    private let stopHostAudioSource: @MainActor (UUID) -> Void
    private let detachAudioEmitter: @MainActor () -> Void
    private(set) var isActive = true

    init(
        enemyID: UUID,
        audioController: GravitasDemoAudioController,
        audioEmitter: Entity?
    ) {
        self.enemyID = enemyID
        stopHostAudioSource = { [weak audioController] enemyID in
            audioController?.stopHostAudioSource(id: enemyID)
        }
        detachAudioEmitter = { [weak audioEmitter] in
            audioEmitter?.removeFromParent()
        }
    }

    init(
        enemyID: UUID,
        stopHostAudioSource: @escaping @MainActor (UUID) -> Void,
        detachAudioEmitter: @escaping @MainActor () -> Void = {}
    ) {
        self.enemyID = enemyID
        self.stopHostAudioSource = stopHostAudioSource
        self.detachAudioEmitter = detachAudioEmitter
    }

    func deactivate(reason: String) async {
        let wasActive = isActive
        stopHostAudioSource(enemyID)
        detachAudioEmitter()
        isActive = false
        print(
            "[Chapter01RobotAudio] force-deactivated " +
                "enemyID=\(enemyID.uuidString) " +
                "wasActive=\(wasActive) reason=\(reason)"
        )
    }
}
