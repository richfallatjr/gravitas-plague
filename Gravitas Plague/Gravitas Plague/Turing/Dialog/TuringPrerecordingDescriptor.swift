import Foundation

struct TuringPrerecordingDescriptor: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let prerecordingID: String
    let speaker: String
    let voiceID: String
    let voiceVariantID: String?
    let audioFile: String
    let transcriptMode: TranscriptMode
    let transcript: String
    let summary: String
    let voicePromptIntent: String
    let defaultEmotion: String

    enum TranscriptMode: String, Codable, Sendable {
        case manual
        case speechToText
        case none
    }
}

struct TuringPrerecordingStore: Sendable {
    func descriptor(id: String) throws -> TuringPrerecordingDescriptor {
        let descriptor = try TuringResourceLoader.decodeResource(
            TuringPrerecordingDescriptor.self,
            resourcePath: "Turing/Prerecordings/\(id).json"
        )
        guard descriptor.schemaVersion == 1 else {
            throw TuringRuntimeError.invalidConfig(
                "Prerecording \(id) schemaVersion must be 1."
            )
        }
        guard descriptor.prerecordingID == id else {
            throw TuringRuntimeError.invalidConfig(
                "Prerecording ID mismatch. Expected \(id), got \(descriptor.prerecordingID)."
            )
        }
        guard descriptor.audioFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Prerecording \(id) audioFile must not be empty."
            )
        }
        return descriptor
    }

    func audioURL(for descriptor: TuringPrerecordingDescriptor) throws -> URL {
        try TuringResourceLoader.resourceURL(
            resourcePath: "Turing/Audio/prerecordings/\(descriptor.audioFile)"
        )
    }
}
