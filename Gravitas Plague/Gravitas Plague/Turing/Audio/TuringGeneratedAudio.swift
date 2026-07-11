import AVFoundation
import Foundation

public struct TuringComputeGapGeneratedAudio: Sendable {
  public let segmentIndex: Int
  public let samples: [Float]
  public let sampleRate: Double
  public let channelCount: AVAudioChannelCount

  public init(
    segmentIndex: Int,
    samples: [Float],
    sampleRate: Double,
    channelCount: AVAudioChannelCount = 1
  ) {
    self.segmentIndex = segmentIndex
    self.samples = samples
    self.sampleRate = sampleRate
    self.channelCount = channelCount
  }
}
