import Foundation

nonisolated enum TuringConversationCharacterID:
    String,
    Codable,
    Sendable,
    Hashable,
    CaseIterable
{
    case rich
    case broadcaster
    case bigMike = "big_mike"
    case catEye81 = "cateye81"
    case dad
}

nonisolated enum TuringConversationSurfaceTargetPolicy: Sendable, Equatable {
    case fixed(TuringConversationCharacterID)
    case explicitPartner(allowed: Set<TuringConversationCharacterID>)
}

nonisolated enum TuringConversationSurfacePolicy {
    static func policy(
        for surface: StoryInteractionSurfaceID
    ) -> TuringConversationSurfaceTargetPolicy {
        switch surface {
        case .dadFrame:
            return .fixed(.rich)
        case .crankRadio:
            return .fixed(.broadcaster)
        case .walkie:
            return .fixed(.bigMike)
        case .hamReceiver:
            return .explicitPartner(allowed: [.catEye81, .dad])
        }
    }

    static func validates(
        target: TuringConversationCharacterID,
        for surface: StoryInteractionSurfaceID
    ) -> Bool {
        switch policy(for: surface) {
        case .fixed(let expected):
            return target == expected
        case .explicitPartner(let allowed):
            return allowed.contains(target)
        }
    }
}
