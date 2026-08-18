import Foundation

@MainActor
final class StoryExperienceModeController {
    static let shared = StoryExperienceModeController()

    private init() {}

    func modeForNewStoryAction() -> StoryExperienceMode {
        .play
    }
}
