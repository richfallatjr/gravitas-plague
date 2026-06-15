import Foundation
import simd

struct AudioFileRef: Hashable {
    let name: String
    let ext: String

    var filename: String {
        "\(name).\(ext)"
    }
}

enum HordePortalAudioSettings {
    static let mixdownName = "hellscape_portal_mixdown"
    static let mixdownExtension = "mp3"

    /// Exposed tuning value for the per-portal hellscape loop.
    static var portalLoopGainDB: Float = -5.0

    /// Spawn sting gain. Tune this after device testing.
    static var portalSpawnGainDB: Float = -5.0

    /// Slightly behind the aperture center so it reads from inside the doorway.
    static let localEmitterOffset = SIMD3<Float>(0, 0, -0.18)

    static let labelPrefix = "hellscape_portal_loop"
    static let spawnLabelPrefix = "hellscape_portal_spawn"

    static let spawnVariants: [AudioFileRef] = [
        AudioFileRef(name: "portal-spawn-01", ext: "wav"),
        AudioFileRef(name: "portal-spawn-02", ext: "wav"),
        AudioFileRef(name: "portal-spawn-03", ext: "wav"),
        AudioFileRef(name: "portal-spawn-04", ext: "wav")
    ]

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

    static func url(
        for file: AudioFileRef
    ) -> URL? {
        Bundle.main.url(
            forResource: file.name,
            withExtension: file.ext
        ) ?? Bundle.main.url(
            forResource: file.name,
            withExtension: file.ext,
            subdirectory: "Audio"
        )
    }

    static func availableSpawnVariants() -> [AudioFileRef] {
        spawnVariants.filter { variant in
            url(for: variant) != nil
        }
    }

    static func randomSpawnVariant() -> AudioFileRef? {
        availableSpawnVariants().randomElement()
    }
}

enum HordePortalAudioAssetValidator {
    static func validate() {
        validateLoop()
        validateSpawnVariants()
    }

    private static func validateLoop() {
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

    private static func validateSpawnVariants() {
        var found = 0

        for variant in HordePortalAudioSettings.spawnVariants {
            if let url = HordePortalAudioSettings.url(for: variant) {
                found += 1

                print(
                    """
                    [HordePortalAudio] found portal spawn asset
                      file: \(variant.filename)
                      url: \(url.path)
                    """
                )
            } else {
                print(
                    """
                    [HordePortalAudio] ERROR missing portal spawn asset
                      file: \(variant.filename)
                      variantWillBeSkipped: true
                      fallback: false
                    """
                )
            }
        }

        print(
            """
            [HordePortalAudio] portal spawn variants validated
              available: \(found)
              expected: \(HordePortalAudioSettings.spawnVariants.count)
            """
        )
    }
}
