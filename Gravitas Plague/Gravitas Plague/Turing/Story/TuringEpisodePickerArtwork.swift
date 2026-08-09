import CoreGraphics
import SwiftUI

enum TuringEpisodePickerArtwork {
    static let plate = "episode-plate-alpha"
    static let continueStrip = "episode-continue-button"
    static let prologueStrip = "episode-prologue-button"
    static let chapter01Strip = "episode-chapter-1-button"
    static let chapter02Strip = "episode-chapter-2-button"
}

struct TuringEpisodeStripArtwork: Sendable, Equatable {
    let assetName: String
    let pixelSize: CGSize

    static let continueStrip = TuringEpisodeStripArtwork(
        assetName: TuringEpisodePickerArtwork.continueStrip,
        pixelSize: CGSize(width: 2953, height: 307)
    )

    static let prologueStrip = TuringEpisodeStripArtwork(
        assetName: TuringEpisodePickerArtwork.prologueStrip,
        pixelSize: CGSize(width: 2953, height: 303)
    )

    static let chapter01Strip = TuringEpisodeStripArtwork(
        assetName: TuringEpisodePickerArtwork.chapter01Strip,
        pixelSize: CGSize(width: 2953, height: 303)
    )

    static let chapter02Strip = TuringEpisodeStripArtwork(
        assetName: TuringEpisodePickerArtwork.chapter02Strip,
        pixelSize: CGSize(width: 2953, height: 303)
    )
}

extension Color {
    static let turingEpisodePickerSurface = Color(
        red: 139.0 / 255.0,
        green: 133.0 / 255.0,
        blue: 121.0 / 255.0
    )
}
