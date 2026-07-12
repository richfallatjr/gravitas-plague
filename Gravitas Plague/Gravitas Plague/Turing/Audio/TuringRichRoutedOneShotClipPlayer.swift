import Foundation

@MainActor
final class TuringRichRoutedOneShotClipPlayer:
  TuringRichGlobalClipPlaying
{
  enum RoutingError: LocalizedError {
    case alreadyPlaying
    case missingHeadsetRoute
    case missingWalkieRoute

    var errorDescription: String? {
      switch self {
      case .alreadyPlaying:
        return "Rich routed player already owns an active clip."
      case .missingHeadsetRoute:
        return "Rich head-tracked audio route is unavailable."
      case .missingWalkieRoute:
        return "Story walkie spatial audio route is unavailable."
      }
    }
  }

  private enum ActiveRoute {
    case headset(
      player: TuringRichHeadsetOneShotClipPlayer,
      handle: TuringRichGlobalClipHandle
    )
    case walkie(
      player: TuringWalkieOneShotClipPlayer,
      walkieHandleID: UUID,
      richHandle: TuringRichGlobalClipHandle
    )
  }

  private var activeRoute: ActiveRoute?

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
    guard activeRoute == nil else {
      throw RoutingError.alreadyPlaying
    }

    switch kind {
    case .walkieOpen, .walkieSend:
      guard let player = TuringStoryWalkieAudioRoute
        .makeActiveClipPlayer()
      else {
        throw RoutingError.missingWalkieRoute
      }
      let richHandle = TuringRichGlobalClipHandle(id: UUID())
      let walkieHandleID = try player.playOneShot(
        fileURL: fileURL,
        kind: .commSFX,
        label: label,
        completion: { [weak self] completedID in
          guard let self else {
            return
          }
          guard case .walkie(
            _,
            let activeID,
            let activeRichHandle
          ) = self.activeRoute,
            activeID == completedID,
            activeRichHandle == richHandle
          else {
            return
          }
          self.activeRoute = nil
          completion(richHandle, true)
        }
      )
      activeRoute = .walkie(
        player: player,
        walkieHandleID: walkieHandleID,
        richHandle: richHandle
      )
      print(
        """
        [TuringRichRoute] clip routed
          kind: \(kind.rawValue)
          label: \(label)
          route: spatialWalkie
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
        """)
      return richHandle

    case .generated, .filler, .prerecording:
      guard let player = TuringRichHeadsetAudioRoute
        .makeActivePlayer()
      else {
        throw RoutingError.missingHeadsetRoute
      }
      let handle = try player.play(
        fileURL: fileURL,
        kind: kind,
        label: label,
        gainDB: gainDB,
        completion: { [weak self] completedHandle, success in
          guard let self else {
            return
          }
          guard case .headset(
            _,
            let activeHandle
          ) = self.activeRoute,
            activeHandle == completedHandle
          else {
            return
          }
          self.activeRoute = nil
          completion(completedHandle, success)
        }
      )
      activeRoute = .headset(
        player: player,
        handle: handle
      )
      print(
        """
        [TuringRichRoute] clip routed
          kind: \(kind.rawValue)
          label: \(label)
          route: headTrackedSpatial
          spatialEmitter: TuringRichHeadset_AudioEmitter
        """)
      return handle
    }
  }

  func cancelActive(reason: String) {
    guard let activeRoute else {
      return
    }
    self.activeRoute = nil

    switch activeRoute {
    case .headset(let player, _):
      player.cancelActive(reason: reason)
    case .walkie(let player, let handleID, _):
      player.cancel(handleID: handleID, reason: reason)
    }
  }
}
