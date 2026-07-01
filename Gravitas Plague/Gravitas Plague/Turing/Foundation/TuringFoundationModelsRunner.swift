import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

protocol TuringFoundationQueryRunning: Sendable {
    func runPrompt(
        _ prompt: String,
        purpose: String
    ) async throws -> String
}

struct TuringFoundationModelsRunner: TuringFoundationQueryRunning {
    func runPrompt(
        _ prompt: String,
        purpose: String
    ) async throws -> String {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel.default

            switch model.availability {
            case .available:
                break
            case .unavailable(let reason):
                print("""
                [TuringFoundation] unavailable
                  purpose: \(purpose)
                  reason: \(String(describing: reason))
                """)
                throw TuringRuntimeError.foundationUnavailable
            @unknown default:
                print("""
                [TuringFoundation] unavailable
                  purpose: \(purpose)
                  reason: unknownAvailability
                """)
                throw TuringRuntimeError.foundationUnavailable
            }

            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return response.content
        }
#endif

        print("""
        [TuringFoundation] unavailable
          purpose: \(purpose)
          reason: FoundationModels framework unavailable on this OS/SDK
        """)
        throw TuringRuntimeError.foundationUnavailable
    }
}
