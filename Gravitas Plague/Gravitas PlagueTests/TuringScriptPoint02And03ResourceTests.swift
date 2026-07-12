import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringScriptPoint02And03ResourceTests: XCTestCase {
  func testScriptPoint02IsRichPRPlusRichTuringFlow() throws {
    let point: TuringWalkieScriptPointDescriptor = try decode(
      "ScriptPoints/prologue.scriptPoint02.json"
    )
    let prerecording: TuringPrerecordingDescriptor = try decode(
      "Prerecordings/prologue.walkie.rich.scriptPoint02.001.json"
    )
    let trigger: TuringVoicePromptTriggerDescriptor = try decode(
      "VoicePrompts/prologue.rich.scriptPoint02.followUp.001.json"
    )

    XCTAssertEqual(point.prerecordingOutputContext, .walkieOutgoingHeadset)
    XCTAssertEqual(point.responseSpeakerID, "rich")
    XCTAssertEqual(point.responseComputeStart, .whenPrerecordingStarts)
    XCTAssertEqual(
      point.responsePlaybackGate,
      .afterPrerecordingActualCompletion
    )
    XCTAssertEqual(point.nextScriptPointID, "prologue.scriptPoint03")
    XCTAssertTrue(point.automaticAdvance)
    XCTAssertFalse(point.conversationRemainsEnabled)

    XCTAssertEqual(prerecording.speaker, "rich")
    XCTAssertEqual(prerecording.voiceID, "rich_base_clone_v1")
    XCTAssertEqual(
      prerecording.audioFile,
      "pr-rich-script-point-02.mp3"
    )
    XCTAssertEqual(trigger.speakerID, "rich")
    XCTAssertEqual(trigger.voiceID, "rich_base_clone_v1")
    XCTAssertEqual(trigger.outputContext, .walkieOutgoingHeadset)
    XCTAssertEqual(
      trigger.conversationKey,
      "dialogue.big_mike.rich"
    )
    XCTAssertTrue(
      (70...90).contains(
        wordCount(prerecording.transcript)
      )
    )
  }

  func testScriptPoint03IsBigMikePRPlusBigMikeTuringFlow() throws {
    let point: TuringWalkieScriptPointDescriptor = try decode(
      "ScriptPoints/prologue.scriptPoint03.json"
    )
    let prerecording: TuringPrerecordingDescriptor = try decode(
      "Prerecordings/prologue.walkie.bigMike.scriptPoint03.001.json"
    )
    let trigger: TuringVoicePromptTriggerDescriptor = try decode(
      "VoicePrompts/prologue.bigMike.scriptPoint03.followUp.001.json"
    )

    XCTAssertEqual(point.prerecordingOutputContext, .walkieSpatial)
    XCTAssertEqual(point.responseSpeakerID, "big_mike")
    XCTAssertEqual(
      point.responseComputeStart,
      .whenPriorGeneratedPlanIsReady
    )
    XCTAssertEqual(
      point.responsePlaybackGate,
      .afterPrerecordingActualCompletion
    )
    XCTAssertFalse(point.automaticAdvance)
    XCTAssertTrue(point.conversationRemainsEnabled)

    XCTAssertEqual(prerecording.speaker, "big_mike")
    XCTAssertEqual(
      prerecording.voiceID,
      "big_mike_base_clone_v1"
    )
    XCTAssertEqual(trigger.speakerID, "big_mike")
    XCTAssertEqual(
      trigger.voiceID,
      "big_mike_base_clone_v1"
    )
    XCTAssertEqual(trigger.outputContext, .walkieSpatial)
    XCTAssertEqual(
      trigger.conversationKey,
      "dialogue.big_mike.rich"
    )
    XCTAssertTrue(
      (70...90).contains(
        wordCount(prerecording.transcript)
      )
    )
  }

  func testScriptPoint02HasNoInteractionGateBeforePoint03() throws {
    let point02: TuringWalkieScriptPointDescriptor = try decode(
      "ScriptPoints/prologue.scriptPoint02.json"
    )
    let point03: TuringWalkieScriptPointDescriptor = try decode(
      "ScriptPoints/prologue.scriptPoint03.json"
    )

    XCTAssertTrue(point02.automaticAdvance)
    XCTAssertEqual(point02.nextScriptPointID, point03.scriptPointID)
    XCTAssertFalse(point02.conversationRemainsEnabled)
    XCTAssertTrue(point03.conversationRemainsEnabled)
  }

  func testRichProfileContainsCanonicalBoundaries() throws {
    let profile: TuringCharacterProfile = try decode(
      "Characters/rich.json"
    )

    XCTAssertEqual(profile.characterID, "rich")
    XCTAssertEqual(
      profile.defaultVoiceID,
      "rich_base_clone_v1"
    )
    XCTAssertTrue(profile.writeup.contains("Cleveland"))
    XCTAssertTrue(profile.writeup.contains("not a soldier"))
    XCTAssertTrue(
      profile.writeup.contains("never becomes omniscient")
    )
  }

  private func decode<T: Decodable>(
    _ relativePath: String
  ) throws -> T {
    let testDirectory = URL(
      fileURLWithPath: #filePath
    ).deletingLastPathComponent()
    let productRoot = testDirectory.deletingLastPathComponent()
    let url =
      productRoot
      .appendingPathComponent("TuringResources/Turing")
      .appendingPathComponent(relativePath)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(
      T.self,
      from: data
    )
  }

  private func wordCount(_ text: String) -> Int {
    text.split {
      $0.isWhitespace || $0.isNewline
    }.count
  }
}
