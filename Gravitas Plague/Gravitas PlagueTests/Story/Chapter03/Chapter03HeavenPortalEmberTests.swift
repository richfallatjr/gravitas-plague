import Foundation
import UIKit
import XCTest
@testable import Gravitas_Plague

final class Chapter03HeavenPortalEmberTests: XCTestCase {
    func testCircularGeometryIsTheSingleExactPortalContract() throws {
        let geometry = try Chapter03CircularPortalGeometry.make(diameterMeters: 2.286)
        XCTAssertEqual(geometry.boundaryPoints.count, 128)
        XCTAssertEqual(geometry.discPositions.count, 129)
        XCTAssertEqual(geometry.triangleIndices.count, 128 * 3)
        XCTAssertEqual(geometry.radiusMeters, 1.143, accuracy: 0.000_001)
        XCTAssertEqual(
            geometry.boundaryPoints[0],
            SIMD3<Float>(1.143, 0, PortalFXDefaults.perimeterSurfaceOffsetMeters)
        )
        XCTAssertEqual(geometry.discPositions[0], .zero)
        XCTAssertTrue(geometry.discPositions.dropFirst().allSatisfy { $0.z == 0 })
    }

    func testHordeAndHeavenPoolBoundsAreExact() {
        XCTAssertEqual(PortalTransitionFXConfiguration.hordePortal.maximumPoolCapacity, 184)
        XCTAssertEqual(
            PortalTransitionFXConfiguration.heavenPortal.maximumPoolCapacity,
            367
        )
        XCTAssertEqual(
            PortalTransitionFXConfiguration.hordePortal.borderRendering,
            .tubeAndJoints
        )
        XCTAssertEqual(
            PortalTransitionFXConfiguration.heavenPortal.borderRendering,
            .embersOnly
        )
    }

    func testDensityMappingUsesApprovedUnsmoothValues() {
        XCTAssertEqual(PortalFXVisemeDensityMapper.multiplier(for: .rest), 1)
        XCTAssertEqual(PortalFXVisemeDensityMapper.multiplier(for: .small), 1.33)
        XCTAssertEqual(PortalFXVisemeDensityMapper.multiplier(for: .round), 1.5)
        XCTAssertEqual(PortalFXVisemeDensityMapper.multiplier(for: .teeth), 1.75)
        XCTAssertEqual(PortalFXVisemeDensityMapper.multiplier(for: .wide), 2)
    }

    func testCoherentMaterialSelectionUsesOneIndexAcrossAllPhases() {
        var generator = SeededTestGenerator(state: 0xA11CE)
        var trackCounts = [0, 0]
        for _ in 0..<100 {
            let indices = PortalEmberMaterialIndexPlanner.choose(
                mode: .coherentTrack,
                counts: .init(birth: 2, hot: 2, red: 2, dark: 2),
                using: &generator
            )
            XCTAssertEqual(indices.birth, indices.hot)
            XCTAssertEqual(indices.hot, indices.late)
            XCTAssertEqual(indices.late, indices.dark)
            trackCounts[indices.birth] += 1
        }
        XCTAssertGreaterThan(trackCounts[0], 35)
        XCTAssertGreaterThan(trackCounts[1], 35)
    }

    @MainActor
    func testHeavenTracksStartBrightAndConvergeToOneDarkPurple() {
        let fuchsiaBirth = hsba(PortalFXPalette.heavenBirthFuchsiaBase)
        let cyanBirth = hsba(PortalFXPalette.heavenBirthCyanBase)
        let latePurple = hsba(PortalFXPalette.heavenLatePurpleBase)
        let darkPurple = hsba(PortalFXPalette.heavenDarkPurpleBase)

        XCTAssertGreaterThanOrEqual(fuchsiaBirth.brightness, 0.99)
        XCTAssertGreaterThanOrEqual(cyanBirth.brightness, 0.99)
        XCTAssertGreaterThan(abs(fuchsiaBirth.hue - cyanBirth.hue), 0.25)

        XCTAssertEqual(
            latePurple.hue,
            PortalFXPalette.heavenPurpleHue,
            accuracy: 0.001
        )
        XCTAssertEqual(
            darkPurple.hue,
            PortalFXPalette.heavenPurpleHue,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(latePurple.saturation, 0.99)
        XCTAssertGreaterThanOrEqual(darkPurple.saturation, 0.99)
        XCTAssertEqual(
            latePurple.brightness,
            PortalFXPalette.bloodRedBrightness,
            accuracy: 0.001
        )
        XCTAssertLessThan(darkPurple.brightness, latePurple.brightness)
    }

    @MainActor
    func testPlaybackSamplesTheMonotonicAudioOrigin() {
        let track = Chapter03AngelVisemeTrack(
            trackID: "test",
            sampleRate: 48_000,
            sampleCount: 1600,
            framesPerSecond: 60,
            frameCount: 2,
            runs: [
                .init(startFrame: 0, endFrameExclusive: 1, pose: .wide),
                .init(startFrame: 1, endFrameExclusive: 2, pose: .teeth),
            ]
        )
        let origin = ContinuousClock.now
        let playback = Chapter03AngelVisemePlayback(
            runID: UUID(),
            playbackID: UUID(),
            track: track,
            clockOrigin: origin
        )
        XCTAssertEqual(playback.sample(now: origin).pose, .wide)
        XCTAssertEqual(
            playback.sample(now: origin.advanced(by: .milliseconds(20))).pose,
            .teeth
        )
        XCTAssertTrue(
            playback.sample(now: origin.advanced(by: .milliseconds(40))).reachedTrackEnd
        )
    }

    func testProductionCueValidatesAgainstCurrentSources() throws {
        let root = try repositoryRoot()
        let resources = root.appendingPathComponent("Gravitas Plague/TuringResources")
        let cueURL = resources.appendingPathComponent(
            "Turing/Cinematics/Chapter03/Cues/" +
                "chapter03.cinematic.angel.lightTunnel.001.visemes.json"
        )
        let descriptorURL = resources.appendingPathComponent(
            "Turing/Cinematics/Chapter03/pr_angel_01.json"
        )
        let audioURL = resources.appendingPathComponent(
            "Turing/Audio/chapter03/pr-angel-01.mp3"
        )
        let manifest = try JSONDecoder().decode(
            Chapter03AngelVisemeManifest.self,
            from: Data(contentsOf: cueURL)
        )
        let track = try Chapter03AngelVisemeTrackStore.validateAndAdapt(
            manifest,
            expectedCinematicID: "chapter03.cinematic.angel.lightTunnel.001",
            expectedDescriptorPath: "Turing/Cinematics/Chapter03/pr_angel_01.json",
            expectedAudioPath: "Turing/Audio/chapter03/pr-angel-01.mp3",
            descriptorSHA256: Chapter03AngelVisemeTrackStore.sha256(
                try Data(contentsOf: descriptorURL)
            ),
            audioSHA256: Chapter03AngelVisemeTrackStore.sha256(
                try Data(contentsOf: audioURL)
            )
        )
        XCTAssertEqual(track.frameCount, 8744)
        XCTAssertEqual(track.runs.count, 723)
        XCTAssertEqual(manifest.summary.unknownPhoneCount, 0)
        XCTAssertEqual(Set(manifest.runs.map(\.pose)), Set(MindEyeMouthPose.allCases))
    }

    func testAngelCueIsNotInTheThirtySevenPRIndex() throws {
        let index = try String(contentsOf: repositoryRoot()
            .appendingPathComponent(
                "Gravitas Plague/TuringResources/Turing/MindsEye/AudioFrames/index.json"
            ))
        XCTAssertFalse(index.contains("chapter03.cinematic.angel.lightTunnel.001"))
    }

    private func repositoryRoot() throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/", cursor.lastPathComponent != "gravitas-plague" {
            cursor.deleteLastPathComponent()
        }
        guard cursor.lastPathComponent == "gravitas-plague" else {
            throw CocoaError(.fileNoSuchFile)
        }
        return cursor
    }

    @MainActor
    private func hsba(
        _ color: UIColor
    ) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ))
        return (hue, saturation, brightness, alpha)
    }
}

private struct SeededTestGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
