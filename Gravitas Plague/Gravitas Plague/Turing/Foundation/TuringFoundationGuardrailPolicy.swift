import Foundation

enum TuringFoundationGuardrailPolicy {
    static let bigMikeConversationResponse = "No you can't say that man"

    static func isGuardrailError(_ error: Error) -> Bool {
        let nsError = error as NSError
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
            || description.contains("safety")
            || description.contains("safe")
            || description.contains("policy")
            || description.contains("not allowed")
    }
}
