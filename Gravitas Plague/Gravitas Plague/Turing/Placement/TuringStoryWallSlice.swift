import Foundation

enum TuringStoryWallSliceOption: String, Codable, Sendable, Hashable, CaseIterable {
    case doorTwo = "D2"
    case benchOne = "B1"
    case windowOne = "W1"
    case windowTwo = "W2"
    case shelfOne = "S1"
    case posterOne = "P1"
}

struct TuringStoryWallSlice: Sendable, Hashable {
    let sliceID: String
    let numericSliceID: Int
    let wallOrdinal: Int
    let wallID: String
    let sourceWallID: String
    let representativeWallUUID: UUID
    let localSliceIndex: Int
    let sliceCountOnWall: Int
    let localMinX: Float
    let localMaxX: Float
    let localCenterX: Float
    let widthMeters: Float
    let isWallStartEdge: Bool
    let isWallEndEdge: Bool
    let floorSupportScore: Float
    let floorEvidenceKnown: Bool
    let wallCenterScore: Float
    let cornerClearanceScore: Float
    let wallStability: Float
    let options: Set<TuringStoryWallSliceOption>

    var optionString: String {
        let ordered = TuringStoryWallSliceOption.allCases
            .filter(options.contains)
            .map(\.rawValue)
        return ordered.isEmpty ? "-" : ordered.joined(separator: ",")
    }
}

struct TuringStoryWallSliceMap: Sendable {
    let perimeter: TuringStorySpinOrderedPerimeter
    let slices: [TuringStoryWallSlice]

    var sliceByID: [String: TuringStoryWallSlice] {
        Dictionary(uniqueKeysWithValues: slices.map { ($0.sliceID, $0) })
    }
}
