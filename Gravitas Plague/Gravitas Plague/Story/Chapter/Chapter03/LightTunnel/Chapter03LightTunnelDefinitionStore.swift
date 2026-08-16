import AVFoundation
import Foundation

nonisolated struct Chapter03LightTunnelResolvedDefinition: Sendable {
    let definition: Chapter03LightTunnelDefinition
    let musicURL: URL
    let musicDurationSeconds: Double
}

nonisolated struct Chapter03LightTunnelDefinitionStore {
    // MP3 frame padding may make an authored 4:00 file report a few
    // hundredths of a second over its program duration.
    nonisolated static let encodedAudioPaddingToleranceSeconds = 0.10
    static let resourcePath =
        "Turing/Chapters/Chapter03/chapter03_light_tunnel_test.json"

    func loadProduction(bundle: Bundle = .main) async throws
        -> Chapter03LightTunnelResolvedDefinition {
        let definition = try TuringResourceLoader.decodeResource(
            Chapter03LightTunnelDefinition.self,
            resourcePath: Self.resourcePath,
            bundle: bundle
        )
        try definition.validate()

        let musicURL: URL
        do {
            musicURL = try TuringResourceLoader.resourceURL(
                resourcePath: definition.music.resourcePath,
                bundle: bundle
            )
        } catch {
            throw Chapter03Error.musicResourceMissing(
                definition.music.resourcePath
            )
        }

        let asset = AVURLAsset(url: musicURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite,
              duration >= definition.music.minimumDurationSeconds,
              duration <= definition.music.maximumDurationSeconds +
                Self.encodedAudioPaddingToleranceSeconds else {
            throw Chapter03Error.musicDurationInvalid(duration)
        }
        return Chapter03LightTunnelResolvedDefinition(
            definition: definition,
            musicURL: musicURL,
            musicDurationSeconds: duration
        )
    }
}
