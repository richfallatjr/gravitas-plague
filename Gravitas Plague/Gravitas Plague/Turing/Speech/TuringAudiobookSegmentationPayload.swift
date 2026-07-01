import Foundation

struct TuringAudiobookSegmentationPayload: Codable, Sendable {
    let schemaVersion: Int?
    let sectionIndex: Int?
    let segments: [Segment]

    struct Segment: Codable, Sendable {
        let index: Int?
        let spokenText: String
        let emotion: String?
    }
}

struct TuringAudiobookSpeechSegment: Codable, Sendable, Hashable {
    let globalIndex: Int
    let sectionIndex: Int
    let localIndex: Int
    let spokenText: String
    let emotion: String
}

struct TuringAudiobookSectionSegmentationResult: Sendable, Hashable {
    let section: TuringAudiobookSourceSection
    let segments: [TuringAudiobookSpeechSegment]
}

struct TuringAudiobookSourcePlan: Sendable, Hashable {
    let normalizedSourceText: String
    let sections: [TuringAudiobookSourceSection]
}

struct TuringPhase1AudiobookPlan: Sendable, Hashable {
    let normalizedSourceText: String
    let sections: [TuringAudiobookSectionSegmentationResult]

    var segmentCount: Int {
        sections.reduce(0) { total, section in
            total + section.segments.count
        }
    }

    var flattenedSegments: [TuringAudiobookSpeechSegment] {
        sections.flatMap(\.segments)
    }
}
