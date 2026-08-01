import Foundation

struct StoryInventorySnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var itemsByID: [String: Int]
    var appliedRewardEventIDs: Set<String>
    var revision: Int

    static let empty = Self(
        schemaVersion: currentSchemaVersion,
        itemsByID: [:],
        appliedRewardEventIDs: [],
        revision: 0
    )
}

struct StoryInventoryGrantResult: Sendable, Equatable {
    let sourceEventID: String
    let wasNewlyApplied: Bool
    let newQuantity: Int
    let revision: Int
}

actor StoryInventoryStore {
    static let shared = StoryInventoryStore()

    private let defaults: UserDefaults
    private let key = "story.inventory.snapshot.v1"
    private var snapshot: StoryInventorySnapshot

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let value = try? JSONDecoder().decode(StoryInventorySnapshot.self, from: data),
           value.schemaVersion == StoryInventorySnapshot.currentSchemaVersion {
            snapshot = value
        } else {
            snapshot = .empty
        }
    }

    func grantIfNeeded(
        eventID: String,
        itemID: String,
        quantity: Int
    ) throws -> StoryInventoryGrantResult {
        guard !eventID.isEmpty, !itemID.isEmpty, quantity > 0 else {
            throw Chapter01RobotError.invalidDefinition("invalid inventory reward request")
        }
        if snapshot.appliedRewardEventIDs.contains(eventID) {
            return StoryInventoryGrantResult(
                sourceEventID: eventID,
                wasNewlyApplied: false,
                newQuantity: snapshot.itemsByID[itemID, default: 0],
                revision: snapshot.revision
            )
        }

        snapshot.itemsByID[itemID, default: 0] += quantity
        snapshot.appliedRewardEventIDs.insert(eventID)
        snapshot.revision += 1
        try persist()
        return StoryInventoryGrantResult(
            sourceEventID: eventID,
            wasNewlyApplied: true,
            newQuantity: snapshot.itemsByID[itemID, default: 0],
            revision: snapshot.revision
        )
    }

    func currentSnapshot() -> StoryInventorySnapshot { snapshot }

    func resetForTesting() throws {
        snapshot = .empty
        try persist()
    }

    private func persist() throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: key)
    }
}
