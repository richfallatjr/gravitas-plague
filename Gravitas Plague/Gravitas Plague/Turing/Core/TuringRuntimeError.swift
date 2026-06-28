import Foundation

enum TuringRuntimeError: LocalizedError, Sendable {
    case resourceMissing(String)
    case invalidConfig(String)
    case foundationUnavailable
    case foundationJSONGateFailed(String)
    case foundationRepairFailed(String)
    case qwenGPUUnavailable
    case qwenModelLoadFailed(String)
    case qwenSynthesisFailed(String)
    case audioCacheFailed(String)
    case playbackFailed(String)
    case bibleUnavailable(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .resourceMissing(let path):
            return "Missing Turing resource: \(path)"
        case .invalidConfig(let detail):
            return "Invalid Turing configuration: \(detail)"
        case .foundationUnavailable:
            return "Foundation Models are unavailable."
        case .foundationJSONGateFailed(let detail):
            return "Foundation Models returned invalid JSON: \(detail)"
        case .foundationRepairFailed(let detail):
            return "Foundation Models JSON repair failed: \(detail)"
        case .qwenGPUUnavailable:
            return "Qwen TTS requires Apple GPU execution and it is unavailable."
        case .qwenModelLoadFailed(let detail):
            return "Qwen model load failed: \(detail)"
        case .qwenSynthesisFailed(let detail):
            return "Qwen synthesis failed: \(detail)"
        case .audioCacheFailed(let detail):
            return "Turing audio cache failed: \(detail)"
        case .playbackFailed(let detail):
            return "Turing playback failed: \(detail)"
        case .bibleUnavailable(let bibleID):
            return "Bible source unavailable: \(bibleID)"
        }
    }
}
