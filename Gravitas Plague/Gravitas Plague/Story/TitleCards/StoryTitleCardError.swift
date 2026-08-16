import Foundation

enum StoryTitleCardError: LocalizedError {
    case transitionAlreadyActive
    case missingTrackedDevicePose
    case missingPresentationOwner
    case missingRouteOwner
    case staleRequest
    case invalidNaturalDestination
    case terminalCardUsedWithUnlockedSuccessor
    case terminalPlaybackIncomplete
    case fullBlackOwnershipRequired

    var errorDescription: String? {
        switch self {
        case .transitionAlreadyActive:
            return "A Story transition is already active."
        case .missingTrackedDevicePose:
            return "The title card could not resolve the headset position."
        case .missingPresentationOwner:
            return "The immersive title-card presenter is unavailable."
        case .missingRouteOwner:
            return "The Story transition route is unavailable."
        case .staleRequest:
            return "The Story title-card request is no longer current."
        case .invalidNaturalDestination:
            return "The requested Chapter transition is not in the production catalog."
        case .terminalCardUsedWithUnlockedSuccessor:
            return "The end card cannot run while another Chapter is available."
        case .terminalPlaybackIncomplete:
            return "The Chapter ending was requested before its final playback completed."
        case .fullBlackOwnershipRequired:
            return "The cinematic requires ownership of an existing full-black transition."
        }
    }
}
