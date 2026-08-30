import Foundation

@MainActor
final class Chapter03AngelPerformanceCoordinator {
    private var playback: Chapter03AngelVisemePlayback?
    private weak var projection: (any Chapter03AngelProjectionPoseReceiving)?
    private weak var blendShape: Chapter03AngelBlendShapeController?
    private weak var embers: Chapter03HeavenPortalEmberController?
    private var activeRunID: UUID?
    private var activePlaybackID: UUID?
    private var lastPose: MindEyeMouthPose?

    func begin(
        start: StorySpatialPrerecordingPlaybackStart,
        track: Chapter03AngelVisemeTrack?,
        projection: (any Chapter03AngelProjectionPoseReceiving)?,
        blendShape: Chapter03AngelBlendShapeController?,
        embers: Chapter03HeavenPortalEmberController?
    ) {
        self.projection = projection
        self.blendShape = blendShape
        self.embers = embers
        activeRunID = start.runID
        activePlaybackID = start.playbackID
        playback = track.map {
            Chapter03AngelVisemePlayback(
                runID: start.runID,
                playbackID: start.playbackID,
                track: $0,
                clockOrigin: start.clockOrigin
            )
        }
        lastPose = nil
        apply(
            Chapter03AngelPerformanceSample(
                runID: start.runID,
                playbackID: start.playbackID,
                frameIndex: 0,
                pose: .rest,
                jawTargetWeight: Chapter03AngelJawPoseMapper.rest,
                emberBirthRateMultiplier: PortalFXVisemeDensityMapper.rest,
                reachedTrackEnd: false
            )
        )
    }

    func update(deltaTime: TimeInterval) {
        if let playback, let runID = activeRunID, let playbackID = activePlaybackID {
            let sampled = playback.sample()
            apply(
                Chapter03AngelPerformanceSample(
                    runID: runID,
                    playbackID: playbackID,
                    frameIndex: sampled.frame,
                    pose: sampled.pose,
                    jawTargetWeight: Chapter03AngelJawPoseMapper.weight(for: sampled.pose),
                    emberBirthRateMultiplier:
                        PortalFXVisemeDensityMapper.multiplier(for: sampled.pose),
                    reachedTrackEnd: sampled.reachedTrackEnd
                )
            )
        }
        blendShape?.update(deltaTime: deltaTime)
    }

    func end(runID: UUID, playbackID: UUID?) {
        guard activeRunID == runID else { return }
        if let playbackID, activePlaybackID != playbackID { return }
        playback = nil
        if let activePlaybackID {
            apply(
                Chapter03AngelPerformanceSample(
                    runID: runID,
                    playbackID: activePlaybackID,
                    frameIndex: 0,
                    pose: .rest,
                    jawTargetWeight: Chapter03AngelJawPoseMapper.rest,
                    emberBirthRateMultiplier: PortalFXVisemeDensityMapper.rest,
                    reachedTrackEnd: true
                )
            )
        }
        activeRunID = nil
        activePlaybackID = nil
    }

    func teardown(reason: String) {
        playback = nil
        activeRunID = nil
        activePlaybackID = nil
        lastPose = nil
        projection?.setAngelMouthPose(.rest)
        embers?.clearPerformanceIdentity()
        blendShape?.reset(immediately: true, reason: reason)
        projection = nil
        blendShape = nil
        embers = nil
    }

    private func apply(_ sample: Chapter03AngelPerformanceSample) {
        guard sample.runID == activeRunID,
              sample.playbackID == activePlaybackID else { return }
        if sample.pose != lastPose {
            lastPose = sample.pose
            projection?.setAngelMouthPose(sample.pose)
            blendShape?.setPose(sample.pose)
        }
        embers?.setPerformanceSample(sample)
    }
}
