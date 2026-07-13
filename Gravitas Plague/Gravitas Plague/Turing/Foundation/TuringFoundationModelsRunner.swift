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

/// The sole production gateway to Apple Foundation Models.
///
/// This type intentionally has no stored properties. Every `runPrompt`
/// invocation constructs one new `LanguageModelSession` in local scope,
/// submits exactly one prompt, and releases that session when the call exits.
struct TuringFoundationModelsRunner: TuringFoundationQueryRunning {
    init() {}

    func runPrompt(
        _ prompt: String,
        purpose: String
    ) async throws -> String {
        let requestID = UUID()

        Self.logExactPrompt(
            prompt,
            purpose: purpose,
            requestID: requestID
        )

#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return try await Self.respondUsingFreshSession(
                prompt: prompt,
                purpose: purpose,
                requestID: requestID
            )
        }
#endif

        print("""
        [TuringFoundation] unavailable
          requestID: \(requestID.uuidString)
          purpose: \(purpose)
          reason: FoundationModels framework unavailable on this OS/SDK
        """)
        throw TuringRuntimeError.foundationUnavailable
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func respondUsingFreshSession(
        prompt: String,
        purpose: String,
        requestID: UUID
    ) async throws -> String {
        let model = FoundationModels.SystemLanguageModel.default

        switch model.availability {
        case .available:
            break

        case .unavailable(let reason):
            print("""
            [TuringFoundation] unavailable
              requestID: \(requestID.uuidString)
              purpose: \(purpose)
              reason: \(String(describing: reason))
            """)
            throw TuringRuntimeError.foundationUnavailable

        @unknown default:
            print("""
            [TuringFoundation] unavailable
              requestID: \(requestID.uuidString)
              purpose: \(purpose)
              reason: unknownAvailability
            """)
            throw TuringRuntimeError.foundationUnavailable
        }

        // This local session is submitted exactly one prompt.
        let session = FoundationModels.LanguageModelSession()
        let sessionID = UUID()

        print("""
        [TuringFoundationFreshSession] created
          requestID: \(requestID.uuidString)
          sessionID: \(sessionID.uuidString)
          purpose: \(purpose)
          freshSession: true
          promptSubmissionLimit: 1
        """)

        defer {
            print("""
            [TuringFoundationFreshSession] scope ended
              requestID: \(requestID.uuidString)
              sessionID: \(sessionID.uuidString)
              purpose: \(purpose)
              sessionRetainedByRunner: false
            """)
        }

        do {
            let response = try await session.respond(
                to: prompt
            )

            print("""
            [TuringFoundationFreshSession] response completed
              requestID: \(requestID.uuidString)
              sessionID: \(sessionID.uuidString)
              purpose: \(purpose)
              responseUTF16: \(response.content.utf16.count)
            """)

            return response.content
        } catch {
            print("""
            [TuringFoundationFreshSession] response failed
              requestID: \(requestID.uuidString)
              sessionID: \(sessionID.uuidString)
              purpose: \(purpose)
              error: \(error.localizedDescription)
            """)
            throw error
        }
    }
#endif

    private static func logExactPrompt(
        _ prompt: String,
        purpose: String,
        requestID: UUID
    ) {
        print("""
        [TuringFoundationPrompt] exact prompt sent
          requestID: \(requestID.uuidString)
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
                character.isLetter ||
                character.isNumber ||
                character == "_"
                    ? character
                    : "_"
            }
            let fileName =
                "last_\(String(safePurpose))_prompt.txt"
            let url = directory
                .appendingPathComponent(fileName)

            try prompt.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )

            print("""
            [TuringFoundationPrompt] wrote \(fileName)
              requestID: \(requestID.uuidString)
              path: \(url.path)
            """)
        } catch {
            print("""
            [TuringFoundationPrompt] write failed
              requestID: \(requestID.uuidString)
              purpose: \(purpose)
              error: \(error.localizedDescription)
            """)
        }
    }
}
