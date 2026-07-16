import Foundation

@MainActor
protocol TuringStoryStateTeleportWorld: AnyObject {
    func establishedLayoutFingerprint() throws -> TuringStoryEstablishedLayoutFingerprint
    func quiesceStoryRuntime(teleportID: UUID) async throws
    func applyDoorDestination(
        _ destination: TuringStoryDoorDestination?,
        teleportID: UUID
    ) async throws
    func applyBattleDestination(
        _ destination: TuringStoryBattleDestination,
        teleportID: UUID
    ) async throws
    func applyMediaDestination(
        _ destination: TuringStoryMediaDestination,
        teleportID: UUID
    ) async throws
    func applyWalkieDestination(
        _ destination: TuringStoryWalkieDestination,
        teleportID: UUID
    ) async throws
}
