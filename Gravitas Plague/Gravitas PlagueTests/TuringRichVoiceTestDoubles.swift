import Foundation

@testable import Gravitas_Plague

@MainActor
final class FakeRichGlobalClipPlayer:
  TuringRichGlobalClipPlaying
{

  struct StartedClip: Equatable {
    let handle: TuringRichGlobalClipHandle
    let fileURL: URL
    let kind: TuringRichGlobalClipKind
    let label: String
    let gainDB: Float
  }

  private(set) var startedClips: [StartedClip] = []
  private(set) var cancelReasons: [String] = []

  private var activeHandle: TuringRichGlobalClipHandle?
  private var activeCompletion:
    (
      @MainActor (
        TuringRichGlobalClipHandle,
        Bool
      ) -> Void
    )?

  @discardableResult
  func play(
    fileURL: URL,
    kind: TuringRichGlobalClipKind,
    label: String,
    gainDB: Float,
    completion:
      @escaping @MainActor (
        TuringRichGlobalClipHandle,
        Bool
      ) -> Void
  ) throws -> TuringRichGlobalClipHandle {
    precondition(
      activeHandle == nil,
      "Fake player allows one active clip."
    )

    let handle =
      TuringRichGlobalClipHandle(
        id: UUID()
      )
    activeHandle = handle
    activeCompletion = completion
    startedClips.append(
      StartedClip(
        handle: handle,
        fileURL: fileURL,
        kind: kind,
        label: label,
        gainDB: gainDB
      )
    )
    return handle
  }

  func cancelActive(reason: String) {
    cancelReasons.append(reason)
    activeHandle = nil
    activeCompletion = nil
  }

  func completeActive(
    successfully: Bool = true
  ) {
    guard
      let handle =
        activeHandle,
      let completion =
        activeCompletion
    else {
      assertionFailure(
        "No active fake Rich clip."
      )
      return
    }

    activeHandle = nil
    activeCompletion = nil
    completion(
      handle,
      successfully
    )
  }
}

struct FakeRichTransmissionProvider:
  TuringRichWalkieTransmissionProviding
{

  let envelope: TuringRichWalkieTransmissionEnvelope

  func makeEnvelope() throws
    -> TuringRichWalkieTransmissionEnvelope
  {
    envelope
  }
}

@MainActor
final class FakeGeneratedAudioPlaybackSink:
  TuringGeneratedAudioPlaybackSink
{

  private(set) var events: [String] = []

  func qwenComputeStarted(
    segmentIndex: Int
  ) async {
    events.append(
      "started:\(segmentIndex)"
    )
  }

  func qwenComputeFinished(
    segmentIndex: Int,
    audio:
      TuringComputeGapGeneratedAudio
  ) async {
    events.append(
      "finished:\(segmentIndex):\(audio.samples.count)"
    )
  }

  func qwenComputeSkipped(
    segmentIndex: Int,
    reason: String
  ) async {
    events.append(
      "skipped:\(segmentIndex):\(reason)"
    )
  }

  func qwenComputeAllFinished() async {
    events.append("allFinished")
  }
}
