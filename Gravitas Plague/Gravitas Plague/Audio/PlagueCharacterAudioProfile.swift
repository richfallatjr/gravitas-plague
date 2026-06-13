import Foundation

enum PlagueAudioAssetName {
    static let defaultCharacterLoop = "dad_breathing"
    static let defaultFacePunch = "face-punch_mixdown"

    static let fleshyFacePunch01 = "fleshy-face-punch-01"
    static let robotWalkingLoop = "robot-walking-loop"
    static let robotDamaged01 = "robot-damaged-01"
    static let robotDamaged02 = "robot-damaged-02"
}

struct PlagueCharacterAudioProfile {
    let archetype: PlagueCharacterArchetype

    let breathingOrMovementLoop: String?
    let breathingOrMovementLoopExtension: String?

    let damagedSounds: [String]
    let damagedSoundExtension: String

    let facePunchContactSounds: [String]
    let facePunchContactExtension: String
}

extension PlagueCharacterArchetype {
    var audioProfile: PlagueCharacterAudioProfile {
        switch self {
        case .robot:
            return PlagueCharacterAudioProfile(
                archetype: self,
                breathingOrMovementLoop: PlagueAudioAssetName.robotWalkingLoop,
                breathingOrMovementLoopExtension: "mp3",
                damagedSounds: [
                    PlagueAudioAssetName.robotDamaged01,
                    PlagueAudioAssetName.robotDamaged02
                ],
                damagedSoundExtension: "wav",
                facePunchContactSounds: [
                    PlagueAudioAssetName.fleshyFacePunch01
                ],
                facePunchContactExtension: "wav"
            )

        case .dad, .spouse, .biker, .grandma, .neighbor:
            return PlagueCharacterAudioProfile(
                archetype: self,
                breathingOrMovementLoop: PlagueAudioAssetName.defaultCharacterLoop,
                breathingOrMovementLoopExtension: "wav",
                damagedSounds: [],
                damagedSoundExtension: "wav",
                facePunchContactSounds: [
                    PlagueAudioAssetName.defaultFacePunch
                ],
                facePunchContactExtension: "wav"
            )
        }
    }
}

enum PlagueRobotAudioAssetValidator {
    static func validate() {
        let required = [
            (PlagueAudioAssetName.fleshyFacePunch01, "wav"),
            (PlagueAudioAssetName.robotWalkingLoop, "mp3"),
            (PlagueAudioAssetName.robotDamaged01, "wav"),
            (PlagueAudioAssetName.robotDamaged02, "wav")
        ]

        for asset in required {
            if let url = Bundle.main.url(
                forResource: asset.0,
                withExtension: asset.1
            ) ?? Bundle.main.url(
                forResource: asset.0,
                withExtension: asset.1,
                subdirectory: "Audio"
            ) {
                print(
                    """
                    [PlagueAudio] found robot audio asset
                      file: \(asset.0).\(asset.1)
                      url: \(url.path)
                    """
                )
            } else {
                print(
                    """
                    [PlagueAudio] ERROR missing robot audio asset
                      file: \(asset.0).\(asset.1)
                    """
                )
            }
        }
    }
}
