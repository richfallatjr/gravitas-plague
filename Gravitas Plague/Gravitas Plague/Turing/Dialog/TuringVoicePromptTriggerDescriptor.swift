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
    promptContext: String? = nil
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
