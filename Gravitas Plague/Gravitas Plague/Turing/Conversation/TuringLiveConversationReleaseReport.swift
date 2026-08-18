import Foundation

nonisolated struct TuringLiveConversationReleaseReport: Sendable, Equatable {
    let activeSessionCount: Int
    let activeDictationCount: Int
    let activeComputeReservationCount: Int
    let activeRenderSessionCount: Int
    let activeDecoderCallCount: Int
    let activeGeneratedPlaybackHandleCount: Int
    let activeInitialFillerTokenCount: Int
    let generatedRunDirectoryExists: Bool
    let transientAudioResourceCount: Int
    let activeHUDDeadlineCount: Int
    let activeChildPresentationCount: Int
    let activeProgressionHoldCount: Int
    let parentLeaseStillCurrent: Bool

    var childReleased: Bool {
        activeSessionCount == 0 &&
            activeDictationCount == 0 &&
            activeComputeReservationCount == 0 &&
            activeRenderSessionCount == 0 &&
            activeDecoderCallCount == 0 &&
            activeGeneratedPlaybackHandleCount == 0 &&
            activeInitialFillerTokenCount == 0 &&
            generatedRunDirectoryExists == false &&
            transientAudioResourceCount == 0 &&
            activeHUDDeadlineCount == 0 &&
            activeChildPresentationCount == 0 &&
            activeProgressionHoldCount == 0
    }
}
