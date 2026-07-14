import TuringQwenNative
import XCTest

@testable import Gravitas_Plague

final class TuringCharacterRuntimeDecodingPolicyTests:
  XCTestCase
{
  func testBigMikeRemainsGreedyAndRichSamplesOnlyTalker()
    throws
  {
    let registry =
      try TuringCharacterRuntimeRegistry()

    let bigMike =
      try registry.require(
        "big_mike"
      )
    let rich =
      try registry.require(
        "rich"
      )

    XCTAssertEqual(
      bigMike.qwen
        .samplingPolicy
        .talker.mode,
      .greedy
    )
    XCTAssertEqual(
      bigMike.qwen
        .samplingPolicy
        .codePredictor.mode,
      .greedy
    )

    XCTAssertEqual(
      rich.qwen
        .samplingPolicy
        .talker.mode,
      .temperatureTopP
    )
    XCTAssertEqual(
      rich.qwen
        .samplingPolicy
        .talker.topK,
      50
    )
    XCTAssertEqual(
      rich.qwen
        .samplingPolicy
        .codePredictor.mode,
      .greedy
    )
    XCTAssertTrue(
      rich.qwen
        .generationQualityPolicy
        .requireEOSBeforeDecode
    )
  }

  func testThirdVoiceDoesNotRequireRendererSwitch()
    throws
  {
    let route =
      TuringVoiceOutputContext(
        rawValue:
          "story.thirdVoice.room"
      )

    let third =
      TuringCharacterRuntimeDefinition(
        characterID:
          "third_voice",
        displayName:
          "Third Voice",
        voiceID:
          "third_voice_clone_v1",
        cloneProfileResourcePath:
          "Turing/Voices/Cloned/Third/third_voice_clone_v1.qwenclone",
        allowedOutputRoutes: [
          route
        ],
        outputProcessing: .init(
          playbackRate: 1
        ),
        qwen: .init(
          maxNewRows: 160,
          useExactReferenceRowCount:
            true,
          referenceWindowStrategy:
            "full",
          skipSegmentFailures:
            true,
          decoding: .init(
            talker: .init(
              mode:
                "temperatureTopP",
              backend:
                "materializedHostTopK",
              temperature: 0.8,
              topK: 40,
              topP: 0.95,
              repetitionPenalty:
                1.05
            ),
            codePredictor: .init(
              mode: "greedy",
              backend:
                "materializedHostTopK",
              temperature: 1,
              topK: 1,
              topP: 1,
              repetitionPenalty: 1
            )
          ),
          qualityGate: .init(
            requireEOSBeforeDecode:
              true,
            minimumPeakAbs:
              0.001,
            minimumRMS:
              0.0001
          )
        ),
        audio: .init(
          generatedGainDB: 0,
          prerecordingGainDB: 0,
          fillerGainDB: -6,
          fillerDirectoryCandidates: [
            "Turing/Audio/third-filler"
          ],
          fillerExtensions: [
            "wav"
          ]
        )
      )

    let registry =
      try TuringCharacterRuntimeRegistry(
        definitions: [third]
      )
    let loaded =
      try registry.require(
        "third_voice"
      )

    XCTAssertEqual(
      loaded.qwen
        .samplingPolicy
        .talker.mode,
      .temperatureTopP
    )
    XCTAssertEqual(
      loaded.qwen
        .samplingPolicy
        .codePredictor.mode,
      .greedy
    )
  }
}
