import AVFoundation
import Foundation

nonisolated struct Chapter03LightTunnelResolvedDefinition: Sendable {
    let definition: Chapter03LightTunnelDefinition
    let musicURL: URL
    let musicDurationSeconds: Double
    let angelPrerecording: Chapter03ResolvedAngelPrerecording?
}

nonisolated struct Chapter03ResolvedAngelPrerecording: Sendable {
    let definition: Chapter03AngelPrerecordingDefinition
    let descriptor: StoryCinematicPrerecordingDescriptor
    let audioURL: URL
    let durationSeconds: Double
    let startMediaTimeSeconds: Double
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

        let resolvedAngel = try await resolveAngelPrerecording(
            definition.angelPrerecording,
            musicDurationSeconds: duration,
            portalArrivalMediaTimeSeconds:
                definition.visual.approachDurationSeconds,
            bundle: bundle
        )
        return Chapter03LightTunnelResolvedDefinition(
            definition: definition,
            musicURL: musicURL,
            musicDurationSeconds: duration,
            angelPrerecording: resolvedAngel
        )
    }

    private func resolveAngelPrerecording(
        _ definition: Chapter03AngelPrerecordingDefinition?,
        musicDurationSeconds: Double,
        portalArrivalMediaTimeSeconds: Double,
        bundle: Bundle
    ) async throws -> Chapter03ResolvedAngelPrerecording? {
        guard let definition else { return nil }

        let descriptor: StoryCinematicPrerecordingDescriptor
        do {
            descriptor = try TuringResourceLoader.decodeResource(
                StoryCinematicPrerecordingDescriptor.self,
                resourcePath: definition.descriptorResourcePath,
                bundle: bundle
            )
        } catch {
            throw Chapter03Error.angelPrerecordingResourceMissing(
                definition.descriptorResourcePath
            )
        }
        guard descriptor.id == "chapter03.cinematic.angel.lightTunnel.001",
              descriptor.outputRoute == .cinematicEmitterSpatial,
              descriptor.audioFile.isEmpty == false else {
            throw Chapter03Error.angelPrerecordingInvalid(
                "descriptor identity, route, or audio path is invalid"
            )
        }

        let audioURL: URL
        do {
            audioURL = try TuringResourceLoader.resourceURL(
                resourcePath: descriptor.audioFile,
                bundle: bundle
            )
        } catch {
            throw Chapter03Error.angelPrerecordingResourceMissing(
                descriptor.audioFile
            )
        }
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw Chapter03Error.angelPrerecordingInvalid(
                "audio duration is not positive"
            )
        }
        let start = try Self.portalArrivalStartMediaTime(
            musicDurationSeconds: musicDurationSeconds,
            portalArrivalMediaTimeSeconds: portalArrivalMediaTimeSeconds,
            prerecordingDurationSeconds: duration
        )
        print(
            """
            [Chapter03AngelPR] portal-arrival timing resolved
              musicDurationSeconds: \(musicDurationSeconds)
              prerecordingDurationSeconds: \(duration)
              startMediaTimeSeconds: \(start)
              expectedEndMediaTimeSeconds: \(start + duration)
              remainingMusicAfterPRSeconds: \(musicDurationSeconds - start - duration)
            """
        )
        return Chapter03ResolvedAngelPrerecording(
            definition: definition,
            descriptor: descriptor,
            audioURL: audioURL,
            durationSeconds: duration,
            startMediaTimeSeconds: start
        )
    }

    nonisolated static func portalArrivalStartMediaTime(
        musicDurationSeconds: Double,
        portalArrivalMediaTimeSeconds: Double,
        prerecordingDurationSeconds: Double
    ) throws -> Double {
        let expectedEnd =
            portalArrivalMediaTimeSeconds + prerecordingDurationSeconds
        guard musicDurationSeconds.isFinite,
              portalArrivalMediaTimeSeconds.isFinite,
              prerecordingDurationSeconds.isFinite,
              portalArrivalMediaTimeSeconds >= 0,
              prerecordingDurationSeconds > 0,
              expectedEnd <= musicDurationSeconds +
                encodedAudioPaddingToleranceSeconds else {
            throw Chapter03Error.angelPrerecordingInvalid(
                "portal-arrival recording does not fit within the music"
            )
        }
        return portalArrivalMediaTimeSeconds
    }
}
