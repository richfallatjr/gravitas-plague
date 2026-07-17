import Foundation

@testable import Gravitas_Plague

actor FakeRichGlobalClipPlayer: TuringAudioPlaybackEndpoint {

  struct StartedClip: Equatable {
    let handle: TuringAudioPlaybackHandle
    let fileURL: URL
    let kind: TuringAudioClipKind
    let label: String
    let gainDB: Float
  }

  private(set) var startedClips: [StartedClip] = []
  private(set) var cancelReasons: [String] = []

  private var activeHandle: TuringAudioPlaybackHandle?
  private let eventHub = TuringAudioEventHub()

  @discardableResult
  func play(
    _ request: TuringAudioPlaybackRequest
  ) async throws -> TuringAudioPlaybackHandle {
    precondition(
      activeHandle == nil,
      "Fake player allows one active clip."
    )

    let handle = TuringAudioPlaybackHandle(
      id: UUID(),
      requestID: request.requestID,
      runID: request.runID,
      route: request.route
    )
    activeHandle = handle
    startedClips.append(
      StartedClip(
        handle: handle,
        fileURL: request.fileURL,
        kind: request.kind,
        label: request.label,
        gainDB: request.gainDB
      )
    )
    await eventHub.yield(.started(handle))
    return handle
  }

  func stop(
    _ handle: TuringAudioPlaybackHandle,
    reason: String
  ) async {
    guard activeHandle == handle else { return }
    cancelReasons.append(reason)
    activeHandle = nil
    await eventHub.yield(.cancelled(handle, reason: reason))
  }

  func completeActive(
    successfully: Bool = true
  ) async {
    guard let handle = activeHandle else {
      assertionFailure(
        "No active fake Rich clip."
      )
      return
    }

    activeHandle = nil
    await eventHub.yield(
      .completed(handle, successfully: successfully)
    )
  }

  func events() async -> AsyncStream<TuringAudioPlaybackEvent> {
    await eventHub.stream()
  }

  func startedKinds() -> [TuringAudioClipKind] {
    startedClips.map(\.kind)
  }

  func lastStartedKind() -> TuringAudioClipKind? {
    startedClips.last?.kind
  }

  func lastStartedLabel() -> String? {
    startedClips.last?.label
  }

  func cancelReasonsSnapshot() -> [String] {
    cancelReasons
  }
}
