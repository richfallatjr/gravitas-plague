import Foundation

struct TuringWalkieScriptPointDescriptor: Codable, Sendable, Hashable {
  enum ResponseComputeStart: String, Codable, Sendable, Hashable {
    case whenPrerecordingStarts
    case whenPriorGeneratedPlanIsReady
  }

  enum ResponsePlaybackGate: String, Codable, Sendable, Hashable {
    case afterPrerecordingActualCompletion
  }

  let schemaVersion: Int
  let scriptPointID: String
  let prerecordingID: String
  let prerecordingOutputContext: TuringVoiceOutputContext
  let responseVoicePromptID: String
  let responseSpeakerID: String
  let responseComputeStart: ResponseComputeStart
  let responsePlaybackGate: ResponsePlaybackGate
  let nextScriptPointID: String?
  let automaticAdvance: Bool
  let conversationRemainsEnabled: Bool
}

struct TuringWalkieScriptPointStore: Sendable {
  func descriptor(id: String) throws -> TuringWalkieScriptPointDescriptor {
    let value = try TuringResourceLoader.decodeResource(
      TuringWalkieScriptPointDescriptor.self,
      resourcePath: "Turing/ScriptPoints/\(id).json"
    )

    guard value.schemaVersion == 1 else {
      throw TuringRuntimeError.invalidConfig(
        "Script point \(id) schemaVersion must be 1."
      )
    }

    guard value.scriptPointID == id else {
      throw TuringRuntimeError.invalidConfig(
        "Script point ID mismatch. Expected \(id), got \(value.scriptPointID)."
      )
    }

    let required = [
      value.prerecordingID,
      value.responseVoicePromptID,
      value.responseSpeakerID,
    ]

    guard
      required.allSatisfy({
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      })
    else {
      throw TuringRuntimeError.invalidConfig(
        "Script point \(id) has an empty required identifier."
      )
    }

    return value
  }
}
