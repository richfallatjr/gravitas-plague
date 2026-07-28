import Foundation

enum TuringFoundationGuardrailPolicy {
    static let bigMikeConversationResponse = "No you can't say that man"

    static func isGuardrailError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "FoundationModels.LanguageModelError",
           nsError.code == 2 {
            return true
        }

        let description = [
            error.localizedDescription,
            String(describing: error),
            String(reflecting: error),
            String(reflecting: type(of: error)),
            String(reflecting: nsError.userInfo)
        ]
        .joined(separator: " ")
        .lowercased()

        return description.contains("guardrail")
            || description.contains("may contain unsafe content")
            || description.contains("safety guardrails were triggered")
    }
}
