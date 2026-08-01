import Foundation

enum Chapter01RobotError: LocalizedError {
    case invalidDefinition(String)
    case missingRewardArt([String])
    case audioEndpointMissing
    case speechAlreadyActive
    case speechNotPrepared(Chapter01RobotSpeechCue)
    case speechPlaybackFailed
    case audioFailure(String)
    case encounterAlreadyActive
    case invalidEncounterState(String)
    case incompleteCleanup(String)

    var errorDescription: String? {
        switch self {
        case .invalidDefinition(let reason):
            return "Invalid Chapter 01 Robot definition: \(reason)"
        case .missingRewardArt(let missing):
            return "Chapter 01 is unavailable until authored reward assets exist: \(missing.joined(separator: ", "))."
        case .audioEndpointMissing:
            return "The Robot spatial speech endpoint is not installed."
        case .speechAlreadyActive:
            return "Robot speech is already active."
        case .speechNotPrepared(let cue):
            return "Robot speech cue \(cue.rawValue) is not prepared."
        case .speechPlaybackFailed:
            return "Robot speech playback did not complete successfully."
        case .audioFailure(let message):
            return "Robot audio failed: \(message)"
        case .encounterAlreadyActive:
            return "The Chapter 01 Robot encounter is already active."
        case .invalidEncounterState(let reason):
            return "Invalid Chapter 01 Robot encounter state: \(reason)"
        case .incompleteCleanup(let reason):
            return "Chapter 01 Robot cleanup was incomplete: \(reason)"
        }
    }
}

struct Chapter01RobotDefinition: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let encounterID: String
    let characterResource: String
    let characterSidecar: String
    let animations: Animations
    let portalPath: PortalPath
    let approach: Approach
    let scan: Scan
    let combat: Combat
    let reward: Reward
    let speechCatalogID: String

    struct Animations: Codable, Sendable, Equatable {
        let idle: String
        let walk: String
        let turnLeft90: String
        let turnRight90: String
        let attacks: [String]
        let deathForward: String
        let deathBackward: String
    }

    struct PortalPath: Codable, Sendable, Equatable {
        let exteriorStartSourceAnchor: String
        let exteriorMidSourceAnchor: String
        let doorThresholdSourceAnchor: String
    }

    struct Approach: Codable, Sendable, Equatable {
        let stopDistanceMeters: Float
        let arrivalToleranceMeters: Float
        let maximumYawRateDegreesPerSecond: Float
    }

    struct Scan: Codable, Sendable, Equatable {
        let sampleRateHz: Double
        let stableDurationSeconds: Double
        let translationToleranceMeters: Float
        let rotationToleranceDegrees: Float
        let trackingLossGraceSeconds: Double
        let movementResetsProgress: Bool
        let trackingLossPausesProgress: Bool
    }

    struct Combat: Codable, Sendable, Equatable {
        let incomingPlayerHitAcceptanceProbability: Double
        let acceptedPlayerHitsToDestroyMinimum: Int
        let acceptedPlayerHitsToDestroyMaximum: Int
        let confirmedRobotHitsToKillPlayer: Int
    }

    struct Reward: Codable, Sendable, Equatable {
        let eventID: String
        let itemID: String
        let quantity: Int
        let hudText: String
    }

    var requiredAnimationIDs: Set<String> {
        Set([
            animations.idle,
            animations.walk,
            animations.turnLeft90,
            animations.turnRight90,
            animations.deathForward,
            animations.deathBackward
        ] + animations.attacks)
    }

    func validate() throws {
        guard schemaVersion == 1,
              encounterID == "chapter01.encounter.gravitasRobot.001",
              characterResource == "robot_biped.usdz",
              characterSidecar == "robot.character.json",
              animations.idle == "drone_idle_01",
              animations.walk == "robot_walk_01",
              animations.turnLeft90 == "turn_left_90",
              animations.turnRight90 == "turn_right_90",
              animations.attacks == [
                  "charged-slash-left",
                  "charged-slash-right",
                  "left_hook_01",
                  "right_hook_01"
              ],
              animations.deathForward == "dead_fall_forward_01",
              animations.deathBackward == "dead_fall_backward_01",
              portalPath.exteriorStartSourceAnchor == "zombieA1",
              portalPath.exteriorMidSourceAnchor == "zombieA2",
              portalPath.doorThresholdSourceAnchor == "zombieA3",
              approach.stopDistanceMeters == 1.5,
              approach.arrivalToleranceMeters == 0.12,
              approach.maximumYawRateDegreesPerSecond == 90,
              scan.sampleRateHz == 30,
              scan.stableDurationSeconds == 5,
              scan.translationToleranceMeters == 0.05,
              scan.rotationToleranceDegrees == 8,
              scan.trackingLossGraceSeconds == 0.35,
              scan.movementResetsProgress,
              scan.trackingLossPausesProgress,
              combat.incomingPlayerHitAcceptanceProbability == 0.1,
              combat.acceptedPlayerHitsToDestroyMinimum == 30,
              combat.acceptedPlayerHitsToDestroyMaximum == 40,
              combat.confirmedRobotHitsToKillPlayer == 5,
              reward.eventID == "chapter01.reward.antigenPack.001",
              reward.itemID == "antigen_pack",
              reward.quantity == 1,
              reward.hudText == "You received an antigen pack",
              speechCatalogID == "chapter01.gravitasRobot.speech.v1",
              requiredAnimationIDs.contains(where: { $0.isEmpty }) == false else {
            throw Chapter01RobotError.invalidDefinition("authored Robot contract changed")
        }
    }
}

struct Chapter01RobotDefinitionStore: Sendable {
    func load() throws -> Chapter01RobotDefinition {
        let definition = try TuringResourceLoader.decodeResource(
            Chapter01RobotDefinition.self,
            resourcePath: "Turing/Story/Chapter01/chapter01.gravitasRobot.001.json"
        )
        try definition.validate()
        return definition
    }
}

enum Chapter01RobotSpeechCue:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case scanInstruction
    case complianceWarning
    case complianceRestored
    case successfulScan
    case payloadRelease
    case exitConfirmation
}

struct Chapter01RobotSpeechCatalog: Codable, Sendable, Equatable {
    struct Cue: Codable, Sendable, Equatable {
        let cueID: Chapter01RobotSpeechCue
        let audioFile: String
        let transcript: String
        let gainDB: Float
    }

    let schemaVersion: Int
    let catalogID: String
    let speakerID: String
    let outputRoute: String
    let cues: [Cue]

    func descriptor(for cue: Chapter01RobotSpeechCue) -> Cue? {
        cues.first { $0.cueID == cue }
    }

    func validate() throws {
        let cueIDs = cues.map(\.cueID)
        let filenames = cues.map(\.audioFile)
        guard schemaVersion == 1,
              catalogID == "chapter01.gravitasRobot.speech.v1",
              speakerID == "gravitas_robot",
              outputRoute == "storyRobotSpatial",
              Set(cueIDs) == Set(Chapter01RobotSpeechCue.allCases),
              cueIDs.count == Chapter01RobotSpeechCue.allCases.count,
              Set(filenames).count == filenames.count,
              cues.allSatisfy({ !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Chapter01RobotError.invalidDefinition("Robot speech catalog is incomplete")
        }
    }

    static func load() throws -> Self {
        let catalog = try TuringResourceLoader.decodeResource(
            Self.self,
            resourcePath: "Turing/Story/Chapter01/chapter01.robot.speech.json"
        )
        try catalog.validate()
        return catalog
    }
}

enum Chapter01RobotResourceResolver {
    static func requirePrerecording(_ filename: String) throws -> URL {
        try TuringResourceLoader.resourceURL(
            resourcePath: "Turing/Audio/prerecordings/\(filename)"
        )
    }
}

struct Chapter01RobotAvailability: Sendable, Equatable {
    let isAvailable: Bool
    let missingAuthoredResources: [String]

    static func evaluate(bundle: Bundle = .main) -> Self {
        let required = [
            "Turing/Story/Chapter01/chapter01.gravitasRobot.001.json",
            "Turing/Story/Chapter01/chapter01.robot.speech.json",
            "Turing/Story/Chapter01/chapter01.music.json",
            "Turing/Story/Chapter01/chapter01.antigenReward.001.json",
            "Turing/Audio/chapter01/dad-window-music.mp3",
            "Turing/Audio/chapter01/robot-beserk-music.mp3",
            "Turing/Audio/prerecordings/pr-robot-scan-instruction.mp3",
            "Turing/Audio/prerecordings/pr-robot-compliance-warning.mp3",
            "Turing/Audio/prerecordings/pr-robot-compliance-restored.mp3",
            "Turing/Audio/prerecordings/pr-robot-successful-scan.mp3",
            "Turing/Audio/prerecordings/pr-robot-payload-release.mp3",
            "Turing/Audio/prerecordings/pr-robot-exit-confirmation.mp3"
        ]
        let missing = required.filter {
            (try? TuringResourceLoader.resourceURL(resourcePath: $0, bundle: bundle)) == nil
        }
        return Self(isAvailable: missing.isEmpty, missingAuthoredResources: missing)
    }
}
