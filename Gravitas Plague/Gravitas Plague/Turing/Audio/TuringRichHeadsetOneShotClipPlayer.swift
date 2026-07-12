import Foundation
import RealityKit

@MainActor
final class TuringRichHeadsetOneShotClipPlayer:
  TuringRichGlobalClipPlaying
{
  enum PlayerError: LocalizedError {
    case missingHeadsetEmitter
    case alreadyPlaying

    var errorDescription: String? {
      switch self {
      case .missingHeadsetEmitter:
        return "Rich headset audio emitter is unavailable."
      case .alreadyPlaying:
        return "Rich headset player already owns an active clip."
      }
    }
  }

  private struct ActiveClip {
    let handle: TuringRichGlobalClipHandle
    let controller: AudioPlaybackController
    let entity: Entity
    let kind: TuringRichGlobalClipKind
    let label: String
    let startedAt: Date
    let completion:
      @MainActor (TuringRichGlobalClipHandle, Bool) -> Void
  }

  private weak var headsetEmitter: Entity?
  private var active: ActiveClip?

  init(headsetEmitter: Entity) {
    self.headsetEmitter = headsetEmitter
  }

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
    guard let headsetEmitter,
      headsetEmitter.parent != nil
    else {
      throw PlayerError.missingHeadsetEmitter
    }

    let resource = try AudioFileResource.load(
      contentsOf: fileURL,
      configuration: AudioFileResource.Configuration(
        loadingStrategy: .preload,
        shouldLoop: false
      )
    )
    let entity = Entity()
    entity.name = "TuringRichHeadsetAudio_\(kind.rawValue)_\(label)"
    entity.components.set(SpatialAudioComponent())
    headsetEmitter.addChild(entity)

    let handle = TuringRichGlobalClipHandle(id: UUID())
    let controller = entity.playAudio(resource)
    controller.gain = Double(gainDB)
    let startedAt = Date()
    active = ActiveClip(
      handle: handle,
      controller: controller,
      entity: entity,
      kind: kind,
      label: label,
      startedAt: startedAt,
      completion: completion
    )
    controller.completionHandler = { [weak self] in
      Task { @MainActor in
        self?.finish(handle: handle, successfully: true)
      }
    }

    print(
      """
      [TuringRichHeadsetPlayer] playback started
        handleID: \(handle.id.uuidString)
        kind: \(kind.rawValue)
        label: \(label)
        file: \(fileURL.lastPathComponent)
        route: headTrackedSpatial
        spatialEmitter: TuringRichHeadset_AudioEmitter
        gainDB: \(String(format: "%.1f", gainDB))
        completionSource: AudioPlaybackController.completionHandler
      """)

    return handle
  }

  func cancelActive(reason: String) {
    guard let active else {
      return
    }
    self.active = nil
    active.controller.stop()
    active.entity.removeFromParent()
    print(
      """
      [TuringRichHeadsetPlayer] playback cancelled
        handleID: \(active.handle.id.uuidString)
        kind: \(active.kind.rawValue)
        reason: \(reason)
      """)
  }

  private func finish(
    handle: TuringRichGlobalClipHandle,
    successfully: Bool
  ) {
    guard let active,
      active.handle == handle
    else {
      print("[TuringRichHeadsetPlayer] stale completion ignored")
      return
    }

    self.active = nil
    active.entity.removeFromParent()
    print(
      """
      [TuringRichHeadsetPlayer] playback completed
        handleID: \(handle.id.uuidString)
        kind: \(active.kind.rawValue)
        label: \(active.label)
        elapsedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(active.startedAt)))
        completionSource: AudioPlaybackController.completionHandler
      """)
    active.completion(handle, successfully)
  }
}

@MainActor
enum TuringRichHeadsetAudioRoute {
  private static var emitter: Entity?
  private static var player: TuringRichHeadsetOneShotClipPlayer?

  static func install(on headAnchor: Entity) {
    clear(reason: "replaceHeadAnchor")

    let emitter = Entity()
    emitter.name = "TuringRichHeadset_AudioEmitter"
    emitter.position = SIMD3<Float>(0, -0.05, -0.10)
    emitter.components.set(SpatialAudioComponent())
    headAnchor.addChild(emitter)

    self.emitter = emitter
    player = TuringRichHeadsetOneShotClipPlayer(
      headsetEmitter: emitter
    )

    print(
      """
      [TuringAudio] Rich headset emitter installed
        emitter: TuringRichHeadset_AudioEmitter
        parent: \(headAnchor.name)
        route: headTrackedSpatial
        localPosition: \(emitter.position)
      """)
  }

  static func makeActivePlayer()
    -> TuringRichHeadsetOneShotClipPlayer?
  {
    player
  }

  static func clear(reason: String) {
    player?.cancelActive(reason: reason)
    player = nil
    emitter?.removeFromParent()
    emitter = nil
  }
}
