import Foundation

nonisolated enum StoryExperienceMode: String, Sendable, Equatable {
    case play
    case interactive
}

nonisolated extension StoryExperienceMode {
    var toggleDestination: StoryExperienceMode {
        switch self {
        case .play: .interactive
        case .interactive: .play
        }
    }

    var posterToggleSymbolName: String {
        switch self {
        case .play: "sparkles"
        case .interactive: "play.fill"
        }
    }

    var posterToggleAccessibilityLabel: String {
        switch self {
        case .play: "Enable Interactive AI mode"
        case .interactive: "Switch to Play mode"
        }
    }

    var posterToggleAccessibilityHint: String {
        switch self {
        case .play:
            "Enables generated character speech, microphones, and player conversation for this app session."
        case .interactive:
            "Uses authored recordings and automatic Story progression without AI generation."
        }
    }
}

