#if canImport(FoundationModels)
import FoundationModels

/// Compile-time fence against accidental long-lived or direct Foundation
/// sessions anywhere in the app target.
///
/// Production code must call `TuringFoundationQueryRunning.runPrompt`.
/// The runner uses the fully qualified SDK name internally and creates one
/// fresh local session for every request.
@available(
    *,
    unavailable,
    message:
        "Direct LanguageModelSession access is forbidden. Use TuringFoundationQueryRunning.runPrompt; it creates one fresh session for every request."
)
typealias LanguageModelSession =
    FoundationModels.LanguageModelSession
#endif
