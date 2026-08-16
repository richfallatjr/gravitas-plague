import Foundation

nonisolated struct Chapter03LightTunnelDefinition: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let sequenceID: String
    let contentRevision: String
    let music: Chapter03LightTunnelMusicDefinition
    let visual: Chapter03LightTunnelVisualDefinition
    let angelPrerecording: Chapter03AngelPrerecordingDefinition?
    let completion: Chapter03LightTunnelCompletionDefinition

    nonisolated func validate() throws {
        guard schemaVersion == 1 else {
            throw Chapter03Error.definitionInvalid("schemaVersion must be 1")
        }
        guard sequenceID == "chapter03.cinematic.lightTunnel.001",
              contentRevision == Chapter03ProgressSnapshot.currentContentRevision else {
            throw Chapter03Error.definitionInvalid("identity or content revision mismatch")
        }
        try music.validate()
        try visual.validate()
        guard completion.waitForMusicActualCompletion,
              completion.waitForAngelPrerecordingIfStarted,
              completion.destination == "endOfAvailableContent" else {
            throw Chapter03Error.definitionInvalid("completion contract mismatch")
        }
        try angelPrerecording?.validate()
    }
}

nonisolated struct Chapter03LightTunnelMusicDefinition: Codable, Sendable, Equatable {
    let resourcePath: String
    let minimumDurationSeconds: Double
    let maximumDurationSeconds: Double
    let loop: Bool
    let gainDB: Float
    let fadeInSeconds: Double
    let fadeOutSeconds: Double

    nonisolated func validate() throws {
        guard !resourcePath.isEmpty,
              minimumDurationSeconds == 180,
              maximumDurationSeconds == 240,
              loop == false,
              gainDB <= 0,
              fadeInSeconds >= 0,
              fadeOutSeconds >= 0 else {
            throw Chapter03Error.definitionInvalid("music contract is invalid")
        }
    }
}

nonisolated struct Chapter03LightTunnelCompletionDefinition: Codable, Sendable, Equatable {
    let waitForMusicActualCompletion: Bool
    let waitForAngelPrerecordingIfStarted: Bool
    let destination: String
}

nonisolated struct Chapter03AngelPrerecordingDefinition: Codable, Sendable, Equatable {
    let descriptorResourcePath: String
    let trigger: Chapter03AngelPrerecordingTrigger
    let musicDuckGainDB: Float
    let duckAttackSeconds: Double
    let duckReleaseSeconds: Double

    nonisolated func validate() throws {
        guard !descriptorResourcePath.isEmpty,
              trigger == .atPortalArrival,
              musicDuckGainDB == -23,
              duckAttackSeconds >= 0,
              duckReleaseSeconds >= 0 else {
            throw Chapter03Error.definitionInvalid("Angel prerecording is only partially configured")
        }
    }
}

nonisolated enum Chapter03AngelPrerecordingTrigger:
    String,
    Codable,
    Sendable,
    Equatable
{
    case atPortalArrival
}
