import Foundation

nonisolated enum TuringRichVoiceIdentity {
    static let characterID = "rich"
    static let speakerID = "rich"
    static let voiceID = "rich_base_clone_v1"
    static let displayName = "Rich"

    static let cloneProfileResourcePath =
        "Turing/Voices/Cloned/Rich/BaseClone/rich_base_clone_v1.qwenclone"

    static let fillerDirectoryCandidates = [
        "Turing/Audio/rich-filler",
        "Turing/rich-filler",
        "rich-filler"
    ]
}

nonisolated enum TuringBigMikeVoiceIdentity {
    static let characterID = "big_mike"
    static let speakerID = "big_mike"
    static let voiceID = "big_mike_base_clone_v1"
    static let displayName = "Big Mike"
}

nonisolated enum TuringBroadcasterVoiceIdentity {
    static let characterID = "broadcaster"
    static let speakerID = "broadcaster"
    static let voiceID = "broadcaster_base_clone_v1"
    static let displayName = "Broadcaster"

    static let cloneProfileResourcePath =
        "Turing/Voices/Cloned/Broadcaster/BaseClone/broadcaster_base_clone_v1.qwenclone"
}

nonisolated enum TuringCatEye81VoiceIdentity {
    static let characterID = "cateye81"
    static let speakerID = "cateye81"
    static let voiceID = "cateye81_base_clone_v1"
    static let displayName = "CatEye81"
    static let prologueProfileID = "cateye81.prologue"

    static let cloneProfileResourcePath =
        "Turing/Voices/Cloned/CatEye81/BaseClone/cateye81_base_clone_v1.qwenclone"
}

nonisolated enum TuringDadVoiceIdentity {
    static let characterID = "dad"
    static let speakerID = "dad"
    static let voiceID = "dad_base_clone_v1"
    static let displayName = "Dad"
    static let chapter02OutbreakNightProfileID =
        "dad.chapter02.outbreakNight"

    static let cloneProfileResourcePath =
        "Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone"
}

nonisolated enum TuringDialogueThreadIdentity {
    static let bigMikeRich = "dialogue.big_mike.rich"
}

/// Extensible route identifier.
///
/// New prop-specific Rich routes are registered by string ID in
/// `TuringFlowRouteRegistry`. Adding a route never requires a new ScriptPoint
/// runner or a change to `TuringFlowEngine`.
nonisolated struct TuringVoiceOutputContext:
    RawRepresentable,
    Codable,
    Sendable,
    Hashable,
    CustomStringConvertible
{
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String {
        rawValue
    }

    static let roomGlobal = Self(rawValue: "roomGlobal")
    static let walkieOutgoingGlobal = Self(rawValue: "walkieOutgoingGlobal")
    static let walkieOutgoingHeadset = Self(rawValue: "walkieOutgoingHeadset")
    static let walkieSpatial = Self(rawValue: "walkieSpatial")
    static let crankRadioSpatial = Self(rawValue: "crankRadioSpatial")
    static let hamReceiverSpatial = Self(rawValue: "hamReceiverSpatial")
}

typealias TuringRichOutputContext = TuringVoiceOutputContext
