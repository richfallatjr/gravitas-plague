import Foundation

struct TuringVoicePromptTriggerDescriptor: Codable, Sendable, Hashable {
  let schemaVersion: Int
  let voicePromptID: String
  let speakerID: String
  let voiceID: String
  let characterProfileID: String
  let listenerProfileID: String
  let outputContext: TuringVoiceOutputContext
  let conversationKey: String
  let intent: String
  let emotion: String
  let promptContext: String?
  let promptTemplateID: TuringVoicePromptTemplateID?
  let communicationMedium: String?

  init(
    schemaVersion: Int,
    voicePromptID: String,
    speakerID: String,
    voiceID: String,
    characterProfileID: String,
    listenerProfileID: String,
    outputContext: TuringVoiceOutputContext,
    conversationKey: String,
    intent: String,
    emotion: String,
    promptContext: String? = nil,
    promptTemplateID: TuringVoicePromptTemplateID? = nil,
    communicationMedium: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.voicePromptID = voicePromptID
    self.speakerID = speakerID
    self.voiceID = voiceID
    self.characterProfileID = characterProfileID
    self.listenerProfileID = listenerProfileID
    self.outputContext = outputContext
    self.conversationKey = conversationKey
    self.intent = intent
    self.emotion = emotion
    self.promptContext = promptContext
    self.promptTemplateID = promptTemplateID
    self.communicationMedium = communicationMedium
  }

  var effectiveAuthoredStoryContext: String {
    let explicit = promptContext?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return explicit.isEmpty
      ? intent.trimmingCharacters(in: .whitespacesAndNewlines)
      : explicit
  }

  var effectivePromptTemplateID: TuringVoicePromptTemplateID {
    promptTemplateID ?? .characterIntent
  }

  var effectiveCommunicationMedium: String {
    if let communicationMedium = communicationMedium?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      communicationMedium.isEmpty == false {
      return communicationMedium
    }
    switch outputContext {
    case .hamReceiverSpatial:
      return "ham radio"
    case .walkieSpatial, .walkieOutgoingGlobal, .walkieOutgoingHeadset:
      return "walkie talkie"
    case .roomGlobal:
      return "the room"
    case .crankRadioSpatial:
      return "public emergency radio"
    default:
      return outputContext.rawValue
    }
  }
}

enum TuringVoicePromptTemplateID:
  String,
  Codable,
  Sendable,
  Hashable
{
  case characterIntent
  case roomObjectMemory
  case broadcasterRadio
  case cateye81HamReceiver
  case richHamReceiver
  case chapter02CharacterIntent
  case chapter02Broadcaster
  case chapter02CatEye81

  var resourcePath: String {
    switch self {
    case .characterIntent:
      return "Turing/Prompts/voicePrompt_characterIntent.txt"
    case .roomObjectMemory:
      return "Turing/Prompts/voicePrompt_roomObjectMemory.txt"
    case .broadcasterRadio:
      return "Turing/Prompts/voicePrompt_broadcasterRadio.txt"
    case .cateye81HamReceiver:
      return "Turing/Prompts/voicePrompt_cateye81HamReceiver.txt"
    case .richHamReceiver:
      return "Turing/Prompts/voicePrompt_richHamReceiver.txt"
    case .chapter02CharacterIntent:
      return "Turing/Prompts/voicePrompt_chapter02CharacterIntent.txt"
    case .chapter02Broadcaster:
      return "Turing/Prompts/voicePrompt_chapter02Broadcaster.txt"
    case .chapter02CatEye81:
      return "Turing/Prompts/voicePrompt_chapter02CatEye81.txt"
    }
  }

  var foundationPurpose: String {
    switch self {
    case .characterIntent:
      return "voicePrompt_characterIntent"
    case .roomObjectMemory:
      return "voicePrompt_roomObjectMemory"
    case .broadcasterRadio:
      return "voicePrompt_broadcasterRadio"
    case .cateye81HamReceiver:
      return "voicePrompt_cateye81HamReceiver"
    case .richHamReceiver:
      return "voicePrompt_richHamReceiver"
    case .chapter02CharacterIntent:
      return "voicePrompt_chapter02CharacterIntent"
    case .chapter02Broadcaster:
      return "voicePrompt_chapter02Broadcaster"
    case .chapter02CatEye81:
      return "voicePrompt_chapter02CatEye81"
    }
  }

  var conversationVariant: TuringConversationPromptVariant {
    switch self {
    case .characterIntent, .chapter02CharacterIntent:
      return .standard
    case .roomObjectMemory:
      return .roomObjectMemory
    case .broadcasterRadio, .chapter02Broadcaster:
      return .broadcasterRadio
    case .cateye81HamReceiver, .chapter02CatEye81:
      return .cateye81HamReceiver
    case .richHamReceiver:
      return .standard
    }
  }
}

struct TuringVoicePromptTriggerStore: Sendable {
  func descriptor(id: String) throws -> TuringVoicePromptTriggerDescriptor {
    let value = try TuringResourceLoader.decodeResource(
      TuringVoicePromptTriggerDescriptor.self,
      resourcePath: "Turing/VoicePrompts/\(id).json"
    )

    guard value.schemaVersion == 1 else {
      throw TuringRuntimeError.invalidConfig(
        "voicePrompt \(id) schemaVersion must be 1."
      )
    }
    guard value.voicePromptID == id else {
      throw TuringRuntimeError.invalidConfig(
        "voicePrompt ID mismatch. Expected \(id), got \(value.voicePromptID)."
      )
    }

    let required: [(String, String)] = [
      ("speakerID", value.speakerID),
      ("voiceID", value.voiceID),
      ("characterProfileID", value.characterProfileID),
      ("listenerProfileID", value.listenerProfileID),
      ("conversationKey", value.conversationKey),
      ("intent", value.intent),
      ("emotion", value.emotion),
    ]

    for (label, rawValue) in required {
      guard rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw TuringRuntimeError.invalidConfig(
          "voicePrompt \(id) \(label) must not be empty."
        )
      }
    }
    if let promptContext = value.promptContext,
       promptContext.trimmingCharacters(
        in: .whitespacesAndNewlines
       ).isEmpty {
      throw TuringRuntimeError.invalidConfig(
        "voicePrompt \(id) promptContext must not be empty when provided."
      )
    }
    _ = try TuringCharacterProfileStore().profile(
      id: value.listenerProfileID
    )

    return value
  }
}

enum TuringPromptVoiceStoryContextBuilder {
  static func standard(
    _ descriptor: TuringVoicePromptTriggerDescriptor
  ) -> TuringAuthoredPromptVoiceContext {
    if descriptor.effectivePromptTemplateID ==
        .roomObjectMemory ||
       descriptor.effectivePromptTemplateID ==
        .broadcasterRadio ||
       descriptor.effectivePromptTemplateID ==
        .cateye81HamReceiver ||
       descriptor.effectivePromptTemplateID ==
        .richHamReceiver {
      return TuringAuthoredPromptVoiceContext(
        voicePromptID: descriptor.voicePromptID,
        storyContext:
          descriptor.effectiveAuthoredStoryContext
      )
    }

    if descriptor.effectivePromptTemplateID == .chapter02CharacterIntent ||
       descriptor.effectivePromptTemplateID == .chapter02Broadcaster ||
       descriptor.effectivePromptTemplateID == .chapter02CatEye81 {
      return TuringAuthoredPromptVoiceContext(
        voicePromptID: descriptor.voicePromptID,
        storyContext: descriptor.effectiveAuthoredStoryContext
      )
    }

    if let promptContext = descriptor.promptContext {
      return TuringAuthoredPromptVoiceContext(
        voicePromptID: descriptor.voicePromptID,
        storyContext: promptContext
      )
    }

    return TuringAuthoredPromptVoiceContext(
      voicePromptID: descriptor.voicePromptID,
      storyContext: """
      Story Intent:
      \(descriptor.intent)
      """
    )
  }

  static func composite(
    _ descriptor: TuringVoicePromptTriggerDescriptor,
    scriptVoiceSource _: String
  ) -> TuringAuthoredPromptVoiceContext {
    standard(descriptor)
  }
}
