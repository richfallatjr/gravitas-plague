import Foundation

enum TuringStorySliceJSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Float)
    case integer(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Float.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        }
    }
}

struct TuringStoryWallSlicePromptDataset: Codable, Sendable {
    let slices: [[TuringStorySliceJSONValue]]

    static func make(from map: TuringStoryWallSliceMap) -> Self {
        let slices = map.slices.prefix(
            TuringStoryWallSlicePromptBudget.maximumTotalSlices
        ).map { slice -> [TuringStorySliceJSONValue] in
            [
                .string(slice.sliceID),
                .string(slice.optionString)
            ]
        }
        return Self(
            slices: slices
        )
    }
}

struct TuringStoryWallSlicePlan: Codable, Sendable {
    let d: [String]?
    let w: [String]?
    let s: [String]?
    let p: [String]?
}

enum TuringStoryWallSliceError: LocalizedError {
    case noWalls
    case noSlices
    case promptTooLarge
    case malformedResponse(String)
    case invalidPlan([String])
    case assetPreparationFailed(String)
    case commitFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWalls: return "No spin-ordered Story walls were available."
        case .noSlices: return "No Story wall slices were available."
        case .promptTooLarge: return "Story wall-slice prompt exceeded the Foundation budget."
        case .malformedResponse(let value): return "Malformed Story wall-slice response: \(value)"
        case .invalidPlan(let issues): return issues.joined(separator: "; ")
        case .assetPreparationFailed(let value): return "Asset preparation failed: \(value)"
        case .commitFailed(let value): return "Atomic slice-layout commit failed: \(value)"
        }
    }
}

enum TuringStoryWallSlicePromptBudget {
    static let hardPromptTokens = 2_300
    static let minimumReservedTokens = 1_200
    static let maximumPromptUTF8Bytes = 8_500
    static let maximumPerimeterWalls = 12
    static let maximumSlicesPerWall = 10
    static let maximumTotalSlices = 120
    static let contextSize = 4_096

    struct Result: Codable, Sendable {
        let promptTokens: Int
        let promptUTF8Bytes: Int
        let reservedTokens: Int
        let withinBudget: Bool
        let tokenCountMode: String
    }

    static func evaluate(_ prompt: String) -> Result {
        let bytes = prompt.utf8.count
        let promptTokens = Int(ceil(Double(bytes) / 3.0))
        let reserved = contextSize - promptTokens
        return Result(
            promptTokens: promptTokens,
            promptUTF8Bytes: bytes,
            reservedTokens: reserved,
            withinBudget: promptTokens <= hardPromptTokens &&
                reserved >= minimumReservedTokens &&
                bytes <= maximumPromptUTF8Bytes,
            tokenCountMode: "conservativeUTF8"
        )
    }
}

struct TuringStoryWallSlicePlannerResult: Sendable {
    let plan: TuringStoryWallSlicePlan
    let rawResponse: String
    let dataset: TuringStoryWallSlicePromptDataset
    let datasetJSON: String
    let renderedPrompt: String
    let repairUsed: Bool
}
