import Foundation

struct TuringStoryPlacementHotspot: Sendable, Hashable {
    let hotspotID: String
    let propID: TuringStoryPropID
    let wallID: String
    let wallUUID: UUID
    let minimumLocalX: Float
    let maximumLocalX: Float
    let recommendedLocalX: Float
    let exactPlacementIDs: [String]
    let bestFloorFrontageScore: Float
    let meanFloorFrontageScore: Float
    let floorEvidenceKnown: Bool
    let bestWallCenterScore: Float
    let bestCornerClearanceScore: Float
    let wallStabilityScore: Float
    let deterministicQuality: Float
}

struct TuringStoryHotspotAtlas: Sendable {
    let hotspots: [TuringStoryPlacementHotspot]
    let hotspotByID: [String: TuringStoryPlacementHotspot]
    let unavoidableConflicts: [[String]]

    func hotspots(for propID: TuringStoryPropID) -> [TuringStoryPlacementHotspot] {
        hotspots.filter { $0.propID == propID }
    }
}
