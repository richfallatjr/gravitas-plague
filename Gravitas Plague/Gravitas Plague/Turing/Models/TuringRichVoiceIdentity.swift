import Foundation

enum TuringRichVoiceIdentity {
  static let characterID = "rich"
  static let speakerID = "rich"
  static let voiceID = "rich_base_clone_v1"
  static let displayName = "Rich"
  static let defaultVariantID = "rich_reference_01"

  static let cloneProfileResourcePath =
    "Turing/Voices/Cloned/Rich/BaseClone/rich_base_clone_v1.qwenclone"

  static let fillerDirectoryCandidates = [
    "Turing/Audio/rich-filler",
    "Turing/rich-filler",
    "rich-filler",
  ]
}

enum TuringBigMikeVoiceIdentity {
  static let characterID = "big_mike"
  static let speakerID = "big_mike"
  static let voiceID = "big_mike_base_clone_v1"
  static let displayName = "Big Mike"
  static let defaultVariantID = "broadcast_reference_fast_01"
}

enum TuringDialogueThreadIdentity {
  static let bigMikeRich = "dialogue.big_mike.rich"
}

enum TuringVoiceOutputContext: String, Codable, Sendable, Hashable {
  // Rich object reactions use this unless a descriptor explicitly opts in
  // to another route.
  case roomGlobal

  // Rich speaking through the walkie. Voice remains global at the player;
  // the open/send comm SFX remain spatial at the authored walkie prop.
  case walkieOutgoingGlobal

  // Retained for decoding older authored descriptors. It is not used by
  // the active ScriptPoint02 route.
  case walkieOutgoingHeadset

  // Remote Big Mike speech at the authored walkie emitter.
  case walkieSpatial
}

typealias TuringRichOutputContext = TuringVoiceOutputContext
