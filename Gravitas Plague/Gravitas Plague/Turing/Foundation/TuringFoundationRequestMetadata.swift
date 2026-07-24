import Foundation

struct TuringFoundationRequestContext: Sendable {
    let flowRunID: String?
    let scriptPointID: String?
    let stageID: String?
    let sectionIndex: Int?

    func withSectionIndex(_ sectionIndex: Int?)
        -> TuringFoundationRequestContext
    {
        TuringFoundationRequestContext(
            flowRunID: flowRunID,
            scriptPointID: scriptPointID,
            stageID: stageID,
            sectionIndex: sectionIndex
        )
    }
}

enum TuringFoundationRequestScope {
    @TaskLocal static var current: TuringFoundationRequestContext?
}

struct TuringFoundationRequestMetadata: Sendable, Codable {
    let requestID: UUID
    let flowRunID: String?
    let scriptPointID: String?
    let stageID: String?
    let sectionIndex: Int?
    let purpose: String
}
