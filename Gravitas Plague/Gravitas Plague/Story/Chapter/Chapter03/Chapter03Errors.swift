import Foundation

enum Chapter03Error: LocalizedError {
    case storyStageNotEstablished
    case incompatibleProgress
    case definitionInvalid(String)
    case musicResourceMissing(String)
    case musicDurationInvalid(Double)
    case musicPlaybackFailed(String)
    case trackedDeviceUnavailable
    case cinematicAnchorUnavailable
    case cinematicAnchorOwned
    case staleRun
    case layoutChangedDuringStart
    case authoredOpeningUnavailable
    case angelResourceMissing(String)
    case angelPoseUnavailable(String)
    case heavenResourceMissing(String)
    case heavenResourceInvalid(String)
    case angelPrerecordingResourceMissing(String)
    case angelPrerecordingInvalid(String)

    var errorDescription: String? {
        switch self {
        case .storyStageNotEstablished:
            return "The established Story room is unavailable."
        case .incompatibleProgress:
            return "Chapter 3 progress is incompatible with this build."
        case .definitionInvalid(let message):
            return "Chapter 3 light-tunnel definition is invalid: \(message)"
        case .musicResourceMissing(let path):
            return "Chapter 3 music is missing at \(path)."
        case .musicDurationInvalid(let duration):
            return "Chapter 3 music duration \(duration) is outside 180 to 240 seconds."
        case .musicPlaybackFailed(let message):
            return "Chapter 3 music playback failed: \(message)"
        case .trackedDeviceUnavailable:
            return "Chapter 3 could not capture a tracked headset transform."
        case .cinematicAnchorUnavailable:
            return "The shared cinematic world anchor is unavailable."
        case .cinematicAnchorOwned:
            return "Another cinematic currently owns the world anchor."
        case .staleRun:
            return "The Chapter 3 run is no longer current."
        case .layoutChangedDuringStart:
            return "The established Story layout changed while Chapter 3 started."
        case .authoredOpeningUnavailable:
            return "The authored Chapter 3 opening is not available in this test build."
        case .angelResourceMissing(let resource):
            return "The Chapter 3 angel resource is missing: \(resource)."
        case .angelPoseUnavailable(let reason):
            return "The Chapter 3 angel pose is unavailable: \(reason)."
        case .heavenResourceMissing(let resource):
            return "The Chapter 3 portal environment is missing: \(resource)."
        case .heavenResourceInvalid(let resource):
            return "The Chapter 3 portal environment could not be decoded: \(resource)."
        case .angelPrerecordingResourceMissing(let resource):
            return "The Chapter 3 Angel recording is missing: \(resource)."
        case .angelPrerecordingInvalid(let reason):
            return "The Chapter 3 Angel recording is invalid: \(reason)."
        }
    }
}
