import Foundation

@MainActor
protocol Chapter01RobotAudioAttachment: AnyObject {
    var enemyID: UUID { get }
    var isActive: Bool { get }

    func deactivate(reason: String) async
}

@MainActor
final class Chapter01RobotAudioAttachmentLease: Chapter01RobotAudioAttachment {
    let enemyID: UUID

    private weak var audioController: GravitasDemoAudioController?
    private(set) var isActive = true

    init(enemyID: UUID, audioController: GravitasDemoAudioController) {
        self.enemyID = enemyID
        self.audioController = audioController
    }

    func deactivate(reason: String) async {
        guard isActive else { return }
        isActive = false
        audioController?.stopHostAudioSource(id: enemyID)
        print(
            "[Chapter01RobotAudio] deactivated enemyID=\(enemyID.uuidString) reason=\(reason)"
        )
    }
}
