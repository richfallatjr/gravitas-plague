import Foundation

enum TuringFoundationGuardrailPolicy {
    static let bigMikeConversationResponse = "No you can't say that man"

    static func isGuardrailError(_ error: Error) -> Bool {
        let description = [
            error.localizedDescription,
            String(describing: error)
        ]
        .joined(separator: " ")
        .lowercased()

        return description.contains("guardrail")
            || description.contains("safety")
            || description.contains("safe")
            || description.contains("policy")
            || description.contains("not allowed")
    }
}
