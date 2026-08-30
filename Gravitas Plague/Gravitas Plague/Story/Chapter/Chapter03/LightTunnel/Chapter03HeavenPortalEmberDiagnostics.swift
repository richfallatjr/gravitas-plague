import Foundation

enum Chapter03HeavenPortalEmberDiagnostics {
    static func poseChanged(
        runID: UUID?,
        playbackID: UUID?,
        frame: Int?,
        pose: MindEyeMouthPose,
        multiplier: Float,
        effectiveBirthRate: Float
    ) {
        let runLabel = runID?.uuidString ?? "none"
        let playbackLabel = playbackID?.uuidString ?? "none"
        let frameLabel = frame.map(String.init) ?? "none"
        print(
            "[Chapter03HeavenEmbers] pose runID=\(runLabel) " +
                "playbackID=\(playbackLabel) " +
                "frame=\(frameLabel) pose=\(pose.rawValue) " +
                "multiplier=\(multiplier) birthRate=\(effectiveBirthRate)"
        )
    }

    static func cueUnavailable(_ error: Error) {
        print("[Chapter03HeavenEmbers] cue unavailable; using rest/1x error=\(error)")
    }

    static func tornDown(reason: String) {
        print("[Chapter03HeavenEmbers] torn down reason=\(reason)")
    }
}
