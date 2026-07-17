import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringAudioMainActorBoundaryTests: XCTestCase {
    func testPlaybackOwnershipIsActorIsolated() throws {
        let coordinator = try appSource(
            "Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
        )
        let routeRuntime = try appSource(
            "Turing/Flow/TuringFlowRouteRuntime.swift"
        )

        XCTAssertTrue(
            coordinator.contains(
                "actor TuringStoryWalkiePlaybackCoordinator"
            )
        )
        XCTAssertFalse(
            routeRuntime.contains(
                "@MainActor\nprotocol TuringFlowPlaybackControlling"
            )
        )
    }

    func testObsoleteMainActorPlayersAreRemoved() throws {
        let removed = [
            "Turing/Audio/TuringWalkieOneShotClipPlayer.swift",
            "Turing/Audio/TuringRichGlobalOneShotClipPlayer.swift",
            "Turing/Audio/TuringRichRoutedOneShotClipPlayer.swift"
        ]
        for relativePath in removed {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: try appSourceURL(relativePath).path
                ),
                "Obsolete MainActor playback owner remains: \(relativePath)"
            )
        }
    }

    func testBlockingAudioPreparationLivesOutsideMainActorAdapters() throws {
        let audioRoot = try appSourceURL("Turing/Audio")
        let files = try FileManager.default.contentsOfDirectory(
            at: audioRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains("@MainActor") else { continue }
            XCTAssertFalse(
                source.contains("AudioFileResource.load("),
                "MainActor resource load remains in \(file.lastPathComponent)"
            )
            XCTAssertFalse(
                source.contains("AVAudioPlayer(contentsOf:"),
                "MainActor AVAudioPlayer setup remains in \(file.lastPathComponent)"
            )
            XCTAssertFalse(
                source.contains("AVAudioFile(forWriting:"),
                "MainActor WAV writing remains in \(file.lastPathComponent)"
            )
        }
    }

    func testActorOwnedTimersDoNotHopToMainActor() throws {
        for relativePath in [
            "Turing/Audio/TuringWalkieCommsFXActor.swift",
            "Turing/Audio/TuringRollingBenchRadioActor.swift"
        ] {
            let source = try appSource(relativePath)
            XCTAssertFalse(source.contains("Task { @MainActor"))
            XCTAssertFalse(source.contains("Task { @MainActor ["))
        }
    }

    private func appSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: try appSourceURL(relativePath),
            encoding: .utf8
        )
    }

    private func appSourceURL(_ relativePath: String) throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let productRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return productRoot
            .appendingPathComponent("Gravitas Plague")
            .appendingPathComponent(relativePath)
    }
}
