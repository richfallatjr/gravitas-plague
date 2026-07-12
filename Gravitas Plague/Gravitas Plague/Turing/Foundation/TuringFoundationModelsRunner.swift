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
        Self.logExactPrompt(
            prompt,
            purpose: purpose
        )
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

            let sessionID = UUID().uuidString
            let session = LanguageModelSession()
            print("""
            [TuringFoundation] fresh session created
              purpose: \(purpose)
              sessionID: \(sessionID)
            """)

            do {
                let response = try await session.respond(
                    to: prompt
                )
                print("""
                [TuringFoundation] fresh session completed
                  purpose: \(purpose)
                  sessionID: \(sessionID)
                """)
                return response.content
            } catch {
                print("""
                [TuringFoundation] fresh session failed
                  purpose: \(purpose)
                  sessionID: \(sessionID)
                  error: \(error.localizedDescription)
                """)
                throw error
            }
        }
#endif

        print("""
        [TuringFoundation] unavailable
          purpose: \(purpose)
          reason: FoundationModels framework unavailable on this OS/SDK
        """)
        throw TuringRuntimeError.foundationUnavailable
    }

    private static func logExactPrompt(
        _ prompt: String,
        purpose: String
    ) {
        print("""
        [TuringFoundationPrompt] exact prompt sent
          purpose: \(purpose)
          promptUTF16: \(prompt.utf16.count)
        [TuringFoundationPrompt] BEGIN \(purpose)
        \(prompt)
        [TuringFoundationPrompt] END \(purpose)
        """)

        do {
            let directory = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent(
                "TuringFoundationLogs",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let safePurpose = purpose.map { character in
                character.isLetter || character.isNumber || character == "_"
                    ? character
                    : "_"
            }
            let fileName = "last_\(String(safePurpose))_prompt.txt"
            let url = directory.appendingPathComponent(fileName)
            try prompt.write(to: url, atomically: true, encoding: .utf8)

            print("""
            [TuringFoundationPrompt] wrote \(fileName)
              path: \(url.path)
            """)
        } catch {
            print("""
            [TuringFoundationPrompt] write failed
              purpose: \(purpose)
              error: \(error.localizedDescription)
            """)
        }
    }
}
