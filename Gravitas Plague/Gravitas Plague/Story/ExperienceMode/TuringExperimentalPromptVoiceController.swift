#if DEBUG || INTERNAL_BUILD
import Combine
import Foundation

@MainActor
final class TuringExperimentalPromptVoiceController: ObservableObject {
    static let shared = TuringExperimentalPromptVoiceController()

    @Published var isEnabled = false

    private init() {}
}
#endif
