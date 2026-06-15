import Foundation
import simd

enum HordePortalAudioSettings {
    static let mixdownName = "hellscape_portal_mixdown"
    static let mixdownExtension = "mp3"

    /// Exposed tuning value for the per-portal hellscape loop.
    static var portalLoopGainDB: Float = -5.0

    /// Slightly behind the aperture center so it reads from inside the doorway.
    static let localEmitterOffset = SIMD3<Float>(0, 0, -0.18)

    static let labelPrefix = "hellscape_portal_loop"

    static func mixdownURL() -> URL? {
        Bundle.main.url(
            forResource: mixdownName,
            withExtension: mixdownExtension
        ) ?? Bundle.main.url(
            forResource: mixdownName,
            withExtension: mixdownExtension,
            subdirectory: "Audio"
        )
    }
}

enum HordePortalAudioAssetValidator {
    static func validate() {
        if let url = HordePortalAudioSettings.mixdownURL() {
            print(
                """
                [HordePortalAudio] found portal loop asset
                  file: \(HordePortalAudioSettings.mixdownName).\(HordePortalAudioSettings.mixdownExtension)
                  url: \(url.path)
                """
            )
        } else {
            print(
                """
                [HordePortalAudio] ERROR missing portal loop asset
                  file: \(HordePortalAudioSettings.mixdownName).\(HordePortalAudioSettings.mixdownExtension)
                  fallback: false
                """
            )
        }
    }
}
