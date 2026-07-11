import Foundation

struct TuringRichWalkieTransmissionEnvelope: Sendable, Equatable {
  let openURL: URL
  let sendURL: URL
}

protocol TuringRichWalkieTransmissionProviding: Sendable {
  func makeEnvelope() throws -> TuringRichWalkieTransmissionEnvelope
}

struct TuringRichWalkieTransmissionController:
  TuringRichWalkieTransmissionProviding,
  Sendable
{

  private let assetStore = TuringWalkieCommsAssetStore()

  func makeEnvelope() throws -> TuringRichWalkieTransmissionEnvelope {
    TuringRichWalkieTransmissionEnvelope(
      openURL: try assetStore.openCommURL(),
      sendURL: try assetStore.sendCommURL()
    )
  }
}
