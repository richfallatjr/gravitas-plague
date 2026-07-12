import AVFoundation
import Foundation

enum TuringRichGlobalClipKind: String, Sendable {
  case generated
  case filler
  case walkieOpen
  case walkieSend
  case prerecording
}

struct TuringRichGlobalClipHandle: Hashable, Sendable {
  let id: UUID
}

@MainActor
protocol TuringRichGlobalClipPlaying: AnyObject {
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
  ) throws -> TuringRichGlobalClipHandle

  func cancelActive(reason: String)
}

@MainActor
final class TuringRichGlobalOneShotClipPlayer: NSObject,
  TuringRichGlobalClipPlaying,
  AVAudioPlayerDelegate
{

  enum PlayerError: LocalizedError {
    case alreadyPlaying
    case couldNotStart(String)

    var errorDescription: String? {
      switch self {
      case .alreadyPlaying:
        return "Rich global player already owns an active clip."
      case .couldNotStart(let label):
        return "Could not start Rich global clip: \(label)."
      }
    }
  }

  private struct ActiveClip {
    let handle: TuringRichGlobalClipHandle
    let player: AVAudioPlayer
    let playerID: ObjectIdentifier
    let kind: TuringRichGlobalClipKind
    let label: String
    let fileURL: URL
    let startedAt: Date
    let expectedDurationSeconds: TimeInterval
    let completion:
      @MainActor (
        TuringRichGlobalClipHandle,
        Bool
      ) -> Void
  }

  private var active: ActiveClip?

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
    guard active == nil else {
      throw PlayerError.alreadyPlaying
    }

    let player = try AVAudioPlayer(contentsOf: fileURL)
    player.numberOfLoops = 0
    player.volume = Self.linearGain(fromDB: gainDB)
    player.delegate = self
    player.prepareToPlay()

    let handle = TuringRichGlobalClipHandle(id: UUID())
    active = ActiveClip(
      handle: handle,
      player: player,
      playerID: ObjectIdentifier(player),
      kind: kind,
      label: label,
      fileURL: fileURL,
      startedAt: Date(),
      expectedDurationSeconds: player.duration,
      completion: completion
    )

    guard player.play() else {
      player.delegate = nil
      active = nil
      throw PlayerError.couldNotStart(label)
    }

    print(
      """
      [TuringRichGlobalPlayer] playback started
        handleID: \(handle.id.uuidString)
        kind: \(kind.rawValue)
        label: \(label)
        file: \(fileURL.lastPathComponent)
        route: global
        spatialEmitter: none
        gainDB: \(String(format: "%.1f", gainDB))
        expectedDurationSeconds: \(String(format: "%.3f", player.duration))
        completionSource: AVAudioPlayerDelegate
      """)

    return handle
  }

  nonisolated func audioPlayerDidFinishPlaying(
    _ player: AVAudioPlayer,
    successfully flag: Bool
  ) {
    let playerID = ObjectIdentifier(player)
    Task { @MainActor [weak self] in
      self?.finish(
        playerID: playerID,
        successfully: flag
      )
    }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(
    _ player: AVAudioPlayer,
    error: Error?
  ) {
    let playerID = ObjectIdentifier(player)
    let message = error?.localizedDescription ?? "unknown decode error"

    Task { @MainActor [weak self] in
      print(
        """
        [TuringRichGlobalPlayer] decode error
          error: \(message)
        """)
      self?.finish(
        playerID: playerID,
        successfully: false
      )
    }
  }

  func cancelActive(reason: String) {
    guard let active else {
      return
    }

    self.active = nil
    active.player.stop()
    active.player.delegate = nil

    print(
      """
      [TuringRichGlobalPlayer] playback cancelled
        handleID: \(active.handle.id.uuidString)
        kind: \(active.kind.rawValue)
        reason: \(reason)
      """)
  }

  private func finish(
    playerID: ObjectIdentifier,
    successfully: Bool
  ) {
    guard let active,
      active.playerID == playerID
    else {
      print("[TuringRichGlobalPlayer] stale completion ignored")
      return
    }

    self.active = nil
    active.player.delegate = nil

    let elapsed = Date().timeIntervalSince(active.startedAt)
    print(
      """
      [TuringRichGlobalPlayer] playback completed
        handleID: \(active.handle.id.uuidString)
        kind: \(active.kind.rawValue)
        label: \(active.label)
        successfully: \(successfully)
        elapsedSeconds: \(String(format: "%.3f", elapsed))
        expectedDurationSeconds: \(String(format: "%.3f", active.expectedDurationSeconds))
        completionFraction: \(String(format: "%.3f", active.expectedDurationSeconds > 0 ? elapsed / active.expectedDurationSeconds : 0))
        completionSource: AVAudioPlayerDelegate
      """)

    active.completion(
      active.handle,
      successfully
    )
  }

  private static func linearGain(fromDB db: Float) -> Float {
    min(1, max(0, pow(10, db / 20)))
  }
}
