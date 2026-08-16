import Foundation

nonisolated struct StoryCinematicPrerecordingDescriptor:
    Codable,
    Sendable,
    Equatable
{
    enum OutputRoute: String, Codable, Sendable {
        case cinematicEmitterSpatial
        case roomGlobal
    }

    let id: String
    let speakerDisplayName: String
    let audioFile: String
    let transcriptMode: String
    let transcript: String
    let outputRoute: OutputRoute
    let gainDB: Float
}
