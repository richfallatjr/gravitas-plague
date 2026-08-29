import Foundation

nonisolated struct MindEyeMotionRuntimeState: Sendable, Equatable {
    var streams: MindEyeMotionRandomStreams
    var drift: MindEyeDriftChannel
    var subject: MindEyeSubjectChannel
    var grip: MindEyeGripCorrectionChannel
    var blink: MindEyeBlinkScheduler
    var simulationTimeSeconds: Double = 0
    var updateIndex: UInt64 = 0

    init(rootSeed: UInt64, tuning: MindEyeKeepAliveTuning) {
        var streams = MindEyeMotionRandomStreams(rootSeed: rootSeed)
        drift = MindEyeDriftChannel()
        subject = MindEyeSubjectChannel()
        grip = MindEyeGripCorrectionChannel(
            random: &streams.grip,
            waitingRange: tuning.gripWaitingSeconds
        )
        blink = MindEyeBlinkScheduler(
            tuning: tuning.blink,
            openVariantCount: tuning.openEyeVariantCount,
            closedVariantCount: tuning.closedEyeVariantCount,
            streams: &streams
        )
        self.streams = streams
    }
}

nonisolated enum MindEyeMotionModel {
    static func advance(
        state: inout MindEyeMotionRuntimeState,
        deltaTime: TimeInterval,
        tuning: MindEyeKeepAliveTuning
    ) -> Result<MindEyeMotionRenderSample, MindEyeFailure> {
        let safeDelta = min(
            max(0, Float(deltaTime)),
            tuning.maximumSimulationStepSeconds
        )
        state.drift.advance(
            deltaTime: safeDelta,
            random: &state.streams.drift,
            transitionRange: tuning.driftTransitionSeconds,
            holdRange: tuning.driftHoldSeconds
        )
        state.subject.advance(
            deltaTime: safeDelta,
            random: &state.streams.subject,
            transitionRange: tuning.subjectTransitionSeconds,
            holdRange: tuning.subjectHoldSeconds
        )
        state.grip.advance(
            deltaTime: safeDelta,
            random: &state.streams.grip,
            waitingRange: tuning.gripWaitingSeconds,
            onsetRange: tuning.gripOnsetSeconds,
            settleRange: tuning.gripSettleSeconds
        )
        state.blink.advance(
            deltaTime: safeDelta,
            tuning: tuning.blink,
            openVariantCount: tuning.openEyeVariantCount,
            closedVariantCount: tuning.closedEyeVariantCount,
            streams: &state.streams
        )
        let camera = MindEyeSelfieCameraPoseBuilder.make(
            driftNormalized: state.drift.current,
            gripNormalized: state.grip.current,
            tuning: tuning
        )
        let subject = MindEyeSelfieCameraPoseBuilder.makeSubjectPose(
            subjectNormalized: state.subject.current,
            tuning: tuning
        )
        switch MindEyeSelfieProjection.project(
            camera: camera,
            subject: subject,
            tuning: tuning
        ) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let projection):
            state.simulationTimeSeconds += Double(safeDelta)
            state.updateIndex &+= 1
            return .success(MindEyeMotionRenderSample(
                backgroundTransform: projection.backgroundTransform,
                characterTransform: projection.characterTransform,
                eyeSelection: state.blink.eyeSelection,
                simulationTimeSeconds: state.simulationTimeSeconds,
                motionUpdateIndex: state.updateIndex,
                blinkCount: state.blink.blinkCount,
                gripCorrectionCount: state.grip.correctionCount
            ))
        }
    }
}
