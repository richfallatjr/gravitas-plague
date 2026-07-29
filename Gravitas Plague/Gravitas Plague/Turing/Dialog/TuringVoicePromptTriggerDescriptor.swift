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
    promptTemplateID: TuringVoicePromptTemplateID? = nil
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

  var resourcePath: String {
    switch self {
    case .characterIntent:
      return "Turing/Prompts/voicePrompt_characterIntent.txt"
    case .roomObjectMemory:
      return "Turing/Prompts/voicePrompt_roomObjectMemory.txt"
    case .broadcasterRadio:
      return "Turing/Prompts/voicePrompt_broadcasterRadio.txt"
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
    }
  }

  var conversationVariant: TuringConversationPromptVariant {
    switch self {
    case .characterIntent:
      return .standard
    case .roomObjectMemory:
      return .roomObjectMemory
    case .broadcasterRadio:
      return .broadcasterRadio
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
        .broadcasterRadio {
      return TuringAuthoredPromptVoiceContext(
        voicePromptID: descriptor.voicePromptID,
        storyContext:
          descriptor.effectiveAuthoredStoryContext
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
