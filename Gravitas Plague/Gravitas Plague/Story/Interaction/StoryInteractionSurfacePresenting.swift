import Foundation

@MainActor
protocol StoryInteractionSurfacePresenting: AnyObject {
    func applyInteractionSnapshot(_ snapshot: StoryInteractionSnapshot)
}
