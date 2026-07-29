import Foundation

protocol TuringGeneratedGapBridge: Sendable {
    func beginGap(
        ownerID: String,
        waitingForSegmentIndex: Int,
        reason: String
    ) async

    func endGap(
        ownerID: String,
        reason: String
    ) async

    func reset(reason: String) async
}
