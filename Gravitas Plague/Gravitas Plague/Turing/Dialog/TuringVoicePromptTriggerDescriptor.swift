import Foundation

struct TuringVoicePromptTriggerDescriptor: Codable, Sendable, Hashable {
  let schemaVersion: Int
  let voicePromptID: String
  let speakerID: String
  let voiceID: String
  let characterProfileID: String
  let outputContext: TuringVoiceOutputContext
  let conversationKey: String
  let intent: String
  let emotion: String
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

    return value
  }
}

enum TuringPromptVoiceSeedBuilder {
  static func standard(
    _ descriptor: TuringVoicePromptTriggerDescriptor
  ) -> TuringPromptVoiceSeed {
    TuringPromptVoiceSeed(
      voicePromptID: descriptor.voicePromptID,
      promptContext: """
      Story intent:
      \(descriptor.intent)

      Emotional tone:
      \(descriptor.emotion)
      """
    )
  }

  static func composite(
    _ descriptor: TuringVoicePromptTriggerDescriptor,
    scriptVoiceSource _: String
  ) -> TuringPromptVoiceSeed {
    standard(descriptor)
  }
}
