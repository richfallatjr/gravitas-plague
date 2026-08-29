import Foundation

nonisolated enum MindEyeResponsePortraitLoadDecision: Sendable, Equatable {
    case allowLoad
    case reuseExistingOnly
    case deny
}
