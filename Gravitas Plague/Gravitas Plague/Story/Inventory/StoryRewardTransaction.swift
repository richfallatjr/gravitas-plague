import Foundation

enum StoryRewardSource: String, Codable, Sendable, Equatable {
    case scanSuccess
    case robotKilled
}

struct StoryRewardRequest: Sendable {
    let eventID: String
    let itemID: String
    let quantity: Int
    let source: StoryRewardSource
    let sourceRuntimeID: UUID
}

struct StoryRewardResult: Sendable, Equatable {
    let wasNewlyGranted: Bool
    let totalQuantity: Int
    let source: StoryRewardSource
}

actor StoryRewardTransaction {
    private let inventory: StoryInventoryStore

    init(inventory: StoryInventoryStore = .shared) {
        self.inventory = inventory
    }

    func grant(_ request: StoryRewardRequest) async throws -> StoryRewardResult {
        let result = try await inventory.grantIfNeeded(
            eventID: request.eventID,
            itemID: request.itemID,
            quantity: request.quantity
        )
        print("""
        [StoryReward] reconciled
          eventID: \(request.eventID)
          sourceRuntimeID: \(request.sourceRuntimeID.uuidString)
          source: \(request.source.rawValue)
          newlyGranted: \(result.wasNewlyApplied)
          totalQuantity: \(result.newQuantity)
        """)
        return StoryRewardResult(
            wasNewlyGranted: result.wasNewlyApplied,
            totalQuantity: result.newQuantity,
            source: request.source
        )
    }
}
