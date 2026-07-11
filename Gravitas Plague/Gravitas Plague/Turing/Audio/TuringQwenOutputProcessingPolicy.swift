import Foundation

struct TuringQwenOutputProcessingPolicy: Sendable, Equatable {
  let voiceID: String
  let playbackRate: Double

  static let bigMike = TuringQwenOutputProcessingPolicy(
    voiceID: TuringBigMikeVoiceIdentity.voiceID,
    playbackRate: 0.85
  )

  static let rich = TuringQwenOutputProcessingPolicy(
    voiceID: TuringRichVoiceIdentity.voiceID,
    playbackRate: 0.85
  )
}
