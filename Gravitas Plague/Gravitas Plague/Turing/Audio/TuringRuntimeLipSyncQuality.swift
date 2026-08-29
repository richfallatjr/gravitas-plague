import Foundation

nonisolated enum TuringRuntimeLipSyncQuality:
    String,
    Sendable,
    Equatable,
    Codable
{
    case forcedTextPhones
    case allPhoneFallback
    case compatibilityDSP
    case restOnly

    var isPhonemeDerived: Bool {
        self == .forcedTextPhones || self == .allPhoneFallback
    }
}

nonisolated enum TuringRuntimeLipSyncFailure: Error, Sendable, Equatable {
    case invalidInput(String)
    case resourceMissing(String)
    case resourceInvalid(String)
    case engineLoadFailed(String)
    case normalizationFailed(String)
    case preprocessingFailed(String)
    case forcedAlignmentFailed(String)
    case allPhoneAlignmentFailed(String)
    case invalidManifest(String)
    case cancelled
    case deadlineExceeded
}
