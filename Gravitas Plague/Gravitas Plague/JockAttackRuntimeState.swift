import Foundation

struct JockActiveAttackState: Equatable {
    let clipID: String
    let metadata: JockAnimClip.AttackMetadata

    var elapsedSeconds: TimeInterval
    var hasDealtDamage: Bool
    var wasCanceled: Bool

    func currentFrame(fps: Double) -> Int {
        max(1, Int(floor(elapsedSeconds * fps)) + 1)
    }

    func isInsideDamageWindow(fps: Double) -> Bool {
        let frame = currentFrame(fps: fps)

        return frame >= metadata.attackWindowStartFrame &&
            frame <= metadata.attackWindowEndFrame
    }
}
