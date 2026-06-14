import Foundation

enum PlagueAudioAssetName {
    static let defaultCharacterLoop = "dad_breathing"
    static let defaultFacePunch = "face-punch_mixdown"

    static let fleshyFacePunch01 = "fleshy-face-punch-01"
    static let robotWalkingLoop = "robot-walking-loop"
    static let robotDamaged01 = "robot-damaged-01"
    static let robotDamaged02 = "robot-damaged-02"
}

struct AudioFileRef: Hashable {
    let name: String
    let ext: String

    var filename: String {
        "\(name).\(ext)"
    }
}

enum PlagueZombieAudioBank {
    static let loopSound = AudioFileRef(
        name: PlagueAudioAssetName.defaultCharacterLoop,
        ext: "wav"
    )

    // No general zombie body-hit bank is currently authored in the project.
    // Keep existing non-robot behavior: confirmed head/face contact audio only.
    static let damageSounds: [AudioFileRef] = []

    static let facePunchContactSounds = [
        AudioFileRef(
            name: PlagueAudioAssetName.defaultFacePunch,
            ext: "wav"
        ),
        AudioFileRef(
            name: PlagueAudioAssetName.fleshyFacePunch01,
            ext: "wav"
        )
    ]
}

enum PlagueCharacterAudioBank: String {
    case zombie
    case robot

    var loopSound: AudioFileRef? {
        switch self {
        case .zombie:
            return PlagueZombieAudioBank.loopSound

        case .robot:
            return AudioFileRef(
                name: PlagueAudioAssetName.robotWalkingLoop,
                ext: "mp3"
            )
        }
    }

    var damageSounds: [AudioFileRef] {
        switch self {
        case .zombie:
            return PlagueZombieAudioBank.damageSounds

        case .robot:
            return [
                AudioFileRef(
                    name: PlagueAudioAssetName.robotDamaged01,
                    ext: "wav"
                ),
                AudioFileRef(
                    name: PlagueAudioAssetName.robotDamaged02,
                    ext: "wav"
                )
            ]
        }
    }

    var facePunchContactSounds: [AudioFileRef] {
        switch self {
        case .zombie:
            return PlagueZombieAudioBank.facePunchContactSounds

        case .robot:
            return [
                AudioFileRef(
                    name: PlagueAudioAssetName.fleshyFacePunch01,
                    ext: "wav"
                )
            ]
        }
    }
}

extension PlagueCharacterArchetype {
    var audioBank: PlagueCharacterAudioBank {
        switch self {
        case .robot:
            return .robot

        case .dad, .spouse, .biker, .grandma, .neighbor:
            return .zombie
        }
    }
}

enum PlagueRobotAudioAssetValidator {
    static func validate() {
        let required = [
            AudioFileRef(
                name: PlagueAudioAssetName.fleshyFacePunch01,
                ext: "wav"
            ),
            AudioFileRef(
                name: PlagueAudioAssetName.robotWalkingLoop,
                ext: "mp3"
            ),
            AudioFileRef(
                name: PlagueAudioAssetName.robotDamaged01,
                ext: "wav"
            ),
            AudioFileRef(
                name: PlagueAudioAssetName.robotDamaged02,
                ext: "wav"
            )
        ]

        for asset in required {
            if let url = Bundle.main.url(
                forResource: asset.name,
                withExtension: asset.ext
            ) ?? Bundle.main.url(
                forResource: asset.name,
                withExtension: asset.ext,
                subdirectory: "Audio"
            ) {
                print(
                    """
                    [PlagueAudio] found robot audio asset
                      file: \(asset.filename)
                      url: \(url.path)
                    """
                )
            } else {
                print(
                    """
                    [PlagueAudio] ERROR missing robot audio asset
                      file: \(asset.filename)
                      robotWillNotFallbackToZombie: true
                    """
                )
            }
        }
    }
}
