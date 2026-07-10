import Foundation

enum TuringCompactJSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Float)
    case integer(Int)
    case boolean(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Float.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }
}

struct TuringStoryHotspotPromptDataset: Codable, Sendable {
    let v: Int
    let scan: String
    let closed: Bool
    let center: [Float]
    let perimeter: [[TuringCompactJSONValue]]
    let priority: [String]
    let required: [Int]
    let props: [String: [Float]]
    let hotspots: [[TuringCompactJSONValue]]
    let conflicts: [[String]]

    static func make(
        perimeter room: TuringStoryRoomPerimeter,
        atlas: TuringStoryHotspotAtlas,
        feasibility: TuringStoryFeasibilityVector,
        posterSize: SIMD2<Float>
    ) -> TuringStoryHotspotPromptDataset {
        let envelopes = TuringStoryPlanningEnvelope.all(posterSize: posterSize)
        var props: [String: [Float]] = [:]
        for envelope in envelopes {
            if envelope.propID == .poster {
                props[envelope.propID.shortID] = [
                    q(envelope.preferredWidthMeters, step: 0.01),
                    q(envelope.reservationHeightMeters, step: 0.01),
                    q(WallPosterPlacementTuning.preferredCenterHeightMeters, step: 0.01),
                    q(WallPosterPlacementTuning.minBottomClearanceMeters, step: 0.01)
                ]
            } else {
                props[envelope.propID.shortID] = [
                    q(envelope.minimumWidthMeters, step: 0.01),
                    q(envelope.maximumWidthMeters, step: 0.01),
                    q(envelope.bottomAboveFloorMeters, step: 0.01),
                    q(envelope.topAboveFloorMeters, step: 0.01),
                    q(envelope.preferredFrontageDepthMeters, step: 0.01)
                ]
            }
        }
        return TuringStoryHotspotPromptDataset(
            v: 1,
            scan: room.scanID,
            closed: room.isClosed,
            center: [q(room.roomCenterXZ.x, step: 0.05), q(room.roomCenterXZ.y, step: 0.05)],
            perimeter: room.wallsClockwise.map { wall in
                [
                    .string(wall.wallID),
                    .number(q(wall.startXZ.x, step: 0.05)),
                    .number(q(wall.startXZ.y, step: 0.05)),
                    .number(q(wall.endXZ.x, step: 0.05)),
                    .number(q(wall.endXZ.y, step: 0.05)),
                    .number(q(wall.heightMeters, step: 0.01)),
                    .number(q(wall.stability, step: 0.01)),
                    .number(q(wall.aggregateFloorFrontageScore, step: 0.01))
                ]
            },
            priority: ["d", "w", "s", "p"],
            required: feasibility.compactArray,
            props: props,
            hotspots: atlas.hotspots.map { hotspot in
                [
                    .string(hotspot.hotspotID),
                    .string(hotspot.propID.shortID),
                    .string(hotspot.wallID),
                    .number(q(hotspot.minimumLocalX, step: 0.05)),
                    .number(q(hotspot.maximumLocalX, step: 0.05)),
                    .number(q(hotspot.recommendedLocalX, step: 0.05)),
                    .number(q(hotspot.bestFloorFrontageScore, step: 0.01)),
                    .number(q(hotspot.meanFloorFrontageScore, step: 0.01)),
                    .integer(hotspot.floorEvidenceKnown ? 1 : 0),
                    .number(q(hotspot.bestWallCenterScore, step: 0.01)),
                    .number(q(hotspot.bestCornerClearanceScore, step: 0.01)),
                    .number(q(hotspot.wallStabilityScore, step: 0.01)),
                    .number(q(hotspot.deterministicQuality, step: 0.01))
                ]
            },
            conflicts: atlas.unavoidableConflicts
        )
    }

    private static func q(_ value: Float, step: Float) -> Float {
        (value / step).rounded() * step
    }
}

struct TuringStoryHotspotPlan: Codable, Sendable {
    let v: Int
    let scan: String
    let a: Assignments
    let b: Assignments?

    init(
        v: Int,
        scan: String,
        a: Assignments,
        b: Assignments? = nil
    ) {
        self.v = v
        self.scan = scan
        self.a = a
        self.b = b
    }

    struct Assignments: Codable, Sendable {
        let d: TuringHotspotSelection?
        let w: TuringHotspotSelection?
        let s: TuringHotspotSelection?
        let p: TuringHotspotSelection?
    }
}

struct TuringHotspotSelection: Codable, Sendable {
    let hotspotID: String
    let normalizedPosition: Float

    init(hotspotID: String, normalizedPosition: Float) {
        self.hotspotID = hotspotID
        self.normalizedPosition = normalizedPosition
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        hotspotID = try container.decode(String.self)
        normalizedPosition = try container.decode(Float.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Hotspot selection must contain exactly [hotspotID, u]."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(hotspotID)
        try container.encode(normalizedPosition)
    }
}

struct TuringStoryHotspotPlanningContext: Sendable {
    let perimeter: TuringStoryRoomPerimeter
    let catalog: TuringStoryExactPlacementCatalog
    let feasibility: TuringStoryFeasibilityVector
    let posterSize: SIMD2<Float>
}

struct TuringStoryHotspotPlannerResult: Sendable {
    let plan: TuringStoryHotspotPlan
    let rawResponse: String
    let atlas: TuringStoryHotspotAtlas
    let dataset: TuringStoryHotspotPromptDataset
    let renderedPrompt: String
    let budget: TuringStoryFoundationPromptBudget.Result
}
