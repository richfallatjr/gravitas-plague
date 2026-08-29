import AVFoundation
import Foundation

public struct TuringComputeGapGeneratedAudio: Sendable {
  public let segmentIndex: Int
  public let samples: [Float]
  public let sampleRate: Double
  public let channelCount: AVAudioChannelCount
  /// Exact input text sent to Qwen, when the producing pipeline has it.
  public let sourceText: String?
  /// Stable identity for the exact text; production logs never print the text.
  public let sourceTextSHA256: String?

  public init(
    segmentIndex: Int,
    samples: [Float],
    sampleRate: Double,
    channelCount: AVAudioChannelCount = 1,
    sourceText: String? = nil
  ) {
    self.segmentIndex = segmentIndex
    self.samples = samples
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.sourceText = sourceText
    self.sourceTextSHA256 = sourceText.map(TuringRuntimeLipSyncSHA256.text)
  }
}
