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

enum TuringFoundationPromptSanitizer {
    static func sanitize(_ prompt: String) -> String {
        prompt.replacingOccurrences(
            of: #"(?i)\bshit\b"#,
            with: "stuff",
            options: .regularExpression
        )
    }
}

enum TuringFoundationModelGuardrailMode: String, Sendable {
    case standard
    case permissiveContentTransformations
}

enum TuringFoundationPromptPurposePolicy {
    static func guardrailMode(
        for purpose: String
    ) -> TuringFoundationModelGuardrailMode {
        switch purpose {
        case "voicePrompt_characterIntent",
             "conversationPrompt_scriptPoint05":
            return .permissiveContentTransformations

        default:
            return .standard
        }
    }
}

enum TuringFoundationErrorDiagnostics {
    static func describe(
        _ error: Error
    ) -> String {
        let nsError = error as NSError
        let localizedError = error as? any LocalizedError

        return """
        type: \(String(reflecting: type(of: error)))
        reflected: \(String(reflecting: error))
        localizedDescription: \(error.localizedDescription)
        failureReason: \(localizedError?.failureReason ?? "none")
        recoverySuggestion: \(localizedError?.recoverySuggestion ?? "none")
        nsDomain: \(nsError.domain)
        nsCode: \(nsError.code)
        nsUserInfo: \(String(reflecting: nsError.userInfo))
        """
    }
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
        let sanitizedPrompt = TuringFoundationPromptSanitizer
            .sanitize(prompt)
        let requestContext = TuringFoundationRequestScope.current
        let sanitizationApplied = sanitizedPrompt != prompt

        if sanitizationApplied {
            print("""
            [TuringFoundationPrompt] sanitized
              requestID: \(requestID.uuidString)
              purpose: \(purpose)
              replacement: shit -> stuff
            """)
        }

        Self.logExactPrompt(
            sanitizedPrompt,
            purpose: purpose,
            requestID: requestID,
            requestContext: requestContext,
            sanitizationApplied: sanitizationApplied
        )

        let metadata = TuringFoundationRequestMetadata(
            requestID: requestID,
            flowRunID: requestContext?.flowRunID,
            scriptPointID: requestContext?.scriptPointID,
            stageID: requestContext?.stageID,
            sectionIndex: requestContext?.sectionIndex,
            purpose: purpose
        )
        let promptURL = try await TuringFoundationPromptArchive.shared
            .archivePrompt(sanitizedPrompt, metadata: metadata)
        print("""
        [TuringFoundationArchive] prompt archived
          requestID: \(requestID.uuidString)
          purpose: \(purpose)
          promptPath: \(promptURL.path)
          beforeFoundationCall: true
        """)

        do {
#if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                let response = try await Self.respondUsingFreshSession(
                    prompt: sanitizedPrompt,
                    purpose: purpose,
                    requestID: requestID
                )
                _ = try? await TuringFoundationPromptArchive.shared
                    .archiveResponse(response, metadata: metadata)
                return response
            }
#endif

            print("""
            [TuringFoundation] unavailable
              requestID: \(requestID.uuidString)
              purpose: \(purpose)
              reason: FoundationModels framework unavailable on this OS/SDK
            """)
            throw TuringRuntimeError.foundationUnavailable
        } catch {
            let errorURL = try? await TuringFoundationPromptArchive.shared
                .archiveError(
                    error,
                    metadata: metadata,
                    prompt: sanitizedPrompt,
                    responseReceived: false
                )
            print("""
            [TuringFoundationArchive] request failed
              requestID: \(requestID.uuidString)
              purpose: \(purpose)
              promptPath: \(promptURL.path)
              errorPath: \(errorURL?.path ?? "unavailable")
              responseReceived: false
              error: \(error.localizedDescription)
            """)
            throw error
        }
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func respondUsingFreshSession(
        prompt: String,
        purpose: String,
        requestID: UUID
    ) async throws -> String {
        let guardrailMode = TuringFoundationPromptPurposePolicy
            .guardrailMode(for: purpose)
        let model: FoundationModels.SystemLanguageModel
        let effectiveGuardrailMode:
            TuringFoundationModelGuardrailMode

        switch guardrailMode {
        case .standard:
            model = .default
            effectiveGuardrailMode = .standard

        case .permissiveContentTransformations:
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                model = FoundationModels.SystemLanguageModel(
                    useCase: .general,
                    guardrails: .permissiveContentTransformations
                )
                effectiveGuardrailMode =
                    .permissiveContentTransformations
            } else {
                model = .default
                effectiveGuardrailMode = .standard
            }
        }

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
        let session = FoundationModels.LanguageModelSession(
            model: model
        )
        let sessionID = UUID()

        print("""
        [TuringFoundationFreshSession] created
          requestID: \(requestID.uuidString)
          sessionID: \(sessionID.uuidString)
          purpose: \(purpose)
          freshSession: true
          promptSubmissionLimit: 1
          requestedGuardrailMode: \(guardrailMode.rawValue)
          effectiveGuardrailMode: \(effectiveGuardrailMode.rawValue)
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
              guardrailMode: \(guardrailMode.rawValue)
              diagnostics:
            \(TuringFoundationErrorDiagnostics.describe(error))
            """)
            throw error
        }
    }
#endif

    private static func logExactPrompt(
        _ prompt: String,
        purpose: String,
        requestID: UUID,
        requestContext: TuringFoundationRequestContext?,
        sanitizationApplied: Bool
    ) {
        if purpose == "conversationPrompt_playerTurn_noBible" ||
            purpose == "conversationPrompt_scriptPoint05" {
            let isScriptPoint05 =
                requestContext?.scriptPointID ==
                "prologue.scriptPoint05"
            let marker =
                isScriptPoint05
                    ? "TuringScriptPoint05ConversationVoiceLLMInput"
                    : "TuringConversationVoiceLLMInput"
            print("""
            [\(marker)] exact Foundation input
              requestID: \(requestID.uuidString)
              flowRunID: \(requestContext?.flowRunID ?? "unscoped")
              scriptPointID: \(requestContext?.scriptPointID ?? "unscoped")
              stageID: \(requestContext?.stageID ?? "conversationVoice")
              purpose: \(purpose)
              sanitizationApplied: \(sanitizationApplied)
              promptUTF16: \(prompt.utf16.count)
              promptSHA256: \(TuringFlowHash.sha256(prompt))
            [\(marker)] BEGIN
            \(prompt)
            [\(marker)] END
            """)
            return
        }

        print("""
        [TuringFoundationPrompt] exact prompt sent
          requestID: \(requestID.uuidString)
          purpose: \(purpose)
          promptUTF16: \(prompt.utf16.count)
        [TuringFoundationPrompt] BEGIN \(purpose)
        \(prompt)
        [TuringFoundationPrompt] END \(purpose)
        """)

    }
}
