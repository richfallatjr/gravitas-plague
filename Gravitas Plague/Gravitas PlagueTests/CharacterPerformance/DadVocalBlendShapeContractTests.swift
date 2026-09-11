import CryptoKit
import Foundation
import RealityKit
import simd
import XCTest

@testable import Gravitas_Plague

final class DadVocalBlendShapeContractTests: XCTestCase {
    func testProductionDescriptorLocksInversePoseMappingAndResponse() throws {
        let descriptor = try productionDescriptor()

        XCTAssertNoThrow(try descriptor.validate())
        XCTAssertEqual(descriptor.descriptorID, "dad.infected.vocalBlendShape.v1")
        XCTAssertEqual(descriptor.characterID, "dad")
        XCTAssertEqual(descriptor.blendShapeName, "dadVocalClose")
        XCTAssertEqual(descriptor.basePose, "wide")
        XCTAssertEqual(descriptor.poseWeights.weight(for: .rest), 1)
        XCTAssertEqual(descriptor.poseWeights.weight(for: .small), 0.5)
        XCTAssertEqual(descriptor.poseWeights.weight(for: .wide), 0)
        XCTAssertEqual(descriptor.poseWeights.weight(for: .round), 0.5)
        XCTAssertEqual(descriptor.poseWeights.weight(for: .teeth), 1)
        XCTAssertEqual(descriptor.fallbackWeight, 1)
        XCTAssertEqual(descriptor.allowedWeightRange, [0, 1])
        XCTAssertEqual(
            descriptor.audioRoles,
            [.presenceLoop, .damageHit, .death]
        )
        XCTAssertEqual(
            descriptor.response,
            .init(
                increasingWeightHalfLifeSeconds: 0.05,
                decreasingWeightHalfLifeSeconds: 0.03,
                crossingHalfLifeSeconds: 0.035,
                maximumDeltaTimeSeconds: 0.05,
                assignmentEpsilon: 0.0005
            )
        )
    }

    func testDescriptorRejectsMappingOrResponseDrift() throws {
        let invalidMapping = try mutatedProductionDescriptor { object in
            var weights = try XCTUnwrap(
                object["poseWeights"] as? [String: Any]
            )
            weights["wide"] = 1.0
            object["poseWeights"] = weights
        }
        XCTAssertThrowsError(try invalidMapping.validate()) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidDescriptor("lockedPoseMapping")
            )
        }

        let invalidResponse = try mutatedProductionDescriptor { object in
            var response = try XCTUnwrap(
                object["response"] as? [String: Any]
            )
            response["decreasingWeightHalfLifeSeconds"] = 0.05
            object["response"] = response
        }
        XCTAssertThrowsError(try invalidResponse.validate()) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidDescriptor("response")
            )
        }

        let breathingRemoved = try mutatedProductionDescriptor { object in
            object["audioRoles"] = [
                "damage_hits",
                "death"
            ]
        }
        XCTAssertThrowsError(try breathingRemoved.validate()) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidDescriptor("audioRoles")
            )
        }
    }

    func testDadInventoryIncludesBreathingAndLocksNineVocalFiles() throws {
        let expected: [DadVocalAudioInventory.Entry] = [
            .init(
                role: .presenceLoop,
                fileName: "dad_breathing.wav",
                sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"
            ),
            .init(
                role: .damageHit,
                fileName: "dad-damaged-01.wav",
                sha256: "fd079a1794c72cd18b565a7398bbb3d601c18fce8be68c85578d0d10f67bf7a5"
            ),
            .init(
                role: .damageHit,
                fileName: "dad-damaged-02.wav",
                sha256: "024cc7fc72276ac2501c729faa97aa5ef855f2739af4d1eba408a6304eca3e71"
            ),
            .init(
                role: .damageHit,
                fileName: "dad-damaged-03.wav",
                sha256: "e28f6eba93636333ead99be7b9059bd9742136375b4aaf87fa1ab1e4e6581da1"
            ),
            .init(
                role: .damageHit,
                fileName: "dad-damaged-04.wav",
                sha256: "4f5fd5842e046ab7a0fc3fb51d4fe38eb5ad4d2f923b3bacf53cb9fa262a2cbf"
            ),
            .init(
                role: .death,
                fileName: "dad-death-01.wav",
                sha256: "670ff38fd3eb5e8f95d1b5848ec346b9a9e7b2f1b610b61a4c6f93e97d40b2f4"
            ),
            .init(
                role: .death,
                fileName: "dad-death-02.wav",
                sha256: "bedad39a231b62e7acb4fc7462680d62d84367e5b3e341ccfe4761774853fcff"
            ),
            .init(
                role: .death,
                fileName: "dad-death-03.wav",
                sha256: "a06c5cf435c3597d7bbd6e98023dc170250e9a95c8bd807fda2ecb67746ff0dc"
            ),
            .init(
                role: .death,
                fileName: "dad-death-04.wav",
                sha256: "48d97a9a5558870a4ba4ee238f805ca4dd86465ffe3bace1898036f66b9dd205"
            )
        ]

        XCTAssertEqual(DadVocalAudioInventory.ordered, expected)
        XCTAssertEqual(
            DadVocalAudioInventory.animatedRoles,
            [.presenceLoop, .damageHit, .death]
        )
        XCTAssertEqual(DadVocalAudioInventory.ordered.count, 9)
        XCTAssertEqual(
            DadVocalAudioInventory.ordered.filter { $0.role == .presenceLoop }.count,
            1
        )
        XCTAssertEqual(
            DadVocalAudioInventory.ordered.filter { $0.role == .damageHit }.count,
            4
        )
        XCTAssertEqual(
            DadVocalAudioInventory.ordered.filter { $0.role == .death }.count,
            4
        )
        XCTAssertEqual(
            Set(DadVocalAudioInventory.ordered.map(\.role)),
            Set(DadVocalAudioInventory.animatedRoles)
        )
        XCTAssertTrue(
            DadVocalAudioInventory.drivesAnimation(
                role: .presenceLoop,
                isLooping: true
            )
        )
        XCTAssertFalse(
            DadVocalAudioInventory.drivesAnimation(
                role: .presenceLoop,
                isLooping: false
            )
        )
        XCTAssertTrue(
            DadVocalAudioInventory.drivesAnimation(
                role: .damageHit,
                isLooping: false
            )
        )
        XCTAssertTrue(
            DadVocalAudioInventory.drivesAnimation(
                role: .death,
                isLooping: false
            )
        )
        XCTAssertFalse(
            DadVocalAudioInventory.drivesAnimation(
                role: .damageHit,
                isLooping: true
            )
        )
        XCTAssertFalse(
            DadVocalAudioInventory.drivesAnimation(
                role: .death,
                isLooping: true
            )
        )
        XCTAssertTrue(DadVocalAudioInventory.ordered.allSatisfy {
            $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit)
        })

        let manifest = try dadCharacterManifestAudio()
        let presence = try XCTUnwrap(
            (manifest["presence_loop"] as? [String: Any])?["file"] as? String
        )
        let damage = soundFileNames(manifest["damage_hits"])
        let death = soundFileNames(manifest["death"])
        let faceHits = Set(soundFileNames(manifest["face_hits"]))
        let attack = soundFileNames(manifest["attack"])

        XCTAssertEqual(
            DadVocalAudioInventory.ordered.map(\.fileName),
            [presence] + damage + death
        )
        XCTAssertEqual(presence, "dad_breathing.wav")
        XCTAssertEqual(
            DadVocalAudioInventory.entry(
                role: .presenceLoop,
                fileName: presence
            ),
            expected[0]
        )
        XCTAssertTrue(
            Set(DadVocalAudioInventory.ordered.map(\.fileName))
                .isDisjoint(with: faceHits)
        )
        XCTAssertTrue(attack.isEmpty)
    }

    func testDadAuthoredVisemeCatalogLoadsNineExactAllPhoneTracks() throws {
        let root = try repositoryRoot()
        let resourceRoot = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague"
        )
        let catalogURL = resourceRoot.appendingPathComponent(
            "CharacterLibrary/FacialPerformance/dad_vocal_viseme_catalog.json"
        )
        let catalog = try JSONDecoder().decode(
            CharacterVocalVisemeCatalog.self,
            from: Data(contentsOf: catalogURL)
        )

        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(catalog.catalogID, "dad.infected.vocalVisemes.v1")
        XCTAssertEqual(catalog.characterID, "dad")
        XCTAssertEqual(
            catalog.compilerVersion,
            "character-vocal-allphone-visemes/1.0.0"
        )
        XCTAssertEqual(catalog.entries.count, 9)
        XCTAssertEqual(
            catalog.entries.map(\.audioFile),
            DadVocalAudioInventory.ordered.map(\.fileName)
        )
        XCTAssertEqual(catalog.entries.filter(\.looping).count, 1)
        XCTAssertEqual(catalog.entries.first?.role, .presenceLoop)
        XCTAssertEqual(catalog.entries.first?.audioFile, "dad_breathing.wav")

        let descriptorHash = try sha256(
            resourceRoot.appendingPathComponent(
                "CharacterLibrary/FacialPerformance/" +
                    "dad_infected_vocal_blendshape.json"
            )
        )
        var identities = Set<CharacterVocalVisemeTrackIdentity>()
        for (entry, inventory) in zip(
            catalog.entries,
            DadVocalAudioInventory.ordered
        ) {
            XCTAssertEqual(entry.role, inventory.role)
            XCTAssertEqual(entry.audioFile, inventory.fileName)
            XCTAssertEqual(entry.audioSHA256, inventory.sha256)
            XCTAssertEqual(entry.looping, entry.role == .presenceLoop)
            XCTAssertTrue(
                entry.manifestResourcePath.hasPrefix(
                    "CharacterLibrary/FacialPerformance/DadVisemes/"
                )
            )

            let manifestURL = resourceRoot.appendingPathComponent(
                entry.manifestResourcePath
            )
            let manifest = try JSONDecoder().decode(
                CharacterVocalVisemeManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            let audioURL = entry.role == .presenceLoop
                ? root.appendingPathComponent(entry.audioFile)
                : resourceRoot.appendingPathComponent("Audio/\(entry.audioFile)")
            let track = try CharacterVocalVisemeTrackStore.validateAndAdapt(
                manifest,
                entry: entry,
                descriptorHash: descriptorHash,
                audioHash: try sha256(audioURL)
            )

            XCTAssertEqual(manifest.alignment.mode, "pocketsphinxAllPhone")
            XCTAssertEqual(manifest.alignment.engine, "pocketsphinx")
            XCTAssertEqual(manifest.alignment.engineVersion, "5.1.1")
            XCTAssertNil(manifest.alignment.transcriptSHA256)
            XCTAssertEqual(
                manifest.requiredPoseFamilies,
                [.rest, .small, .wide, .round, .teeth]
            )
            XCTAssertEqual(track.identity.characterID, "dad")
            XCTAssertEqual(track.identity.role, entry.role)
            XCTAssertEqual(track.identity.audioFile, entry.audioFile)
            XCTAssertEqual(track.identity.audioSHA256, entry.audioSHA256)
            XCTAssertEqual(track.identity.looping, entry.looping)
            XCTAssertEqual(track.sampleRate, 48_000)
            XCTAssertEqual(track.framesPerSecond, 60)
            XCTAssertEqual(track.frameCount, (track.sampleCount + 799) / 800)
            XCTAssertEqual(track.runs.first?.startFrame, 0)
            XCTAssertEqual(track.runs.last?.endFrameExclusive, track.frameCount)
            XCTAssertEqual(track.runs.count, manifest.summary.runCount)
            XCTAssertTrue(identities.insert(track.identity).inserted)
        }
        XCTAssertEqual(identities.count, 9)
    }

    func testCompactVisemeTrackUsesCursorAndFallsBackClosedOutsideTimeline() {
        let identity = CharacterVocalVisemeTrackIdentity(
            characterID: "dad",
            role: .damageHit,
            audioFile: "dad-damaged-01.wav",
            audioSHA256: String(repeating: "a", count: 64),
            looping: false
        )
        let track = CharacterVocalVisemeTrack(
            trackID: "test",
            identity: identity,
            sampleRate: 48_000,
            sampleCount: 8_000,
            framesPerSecond: 60,
            frameCount: 10,
            runsSHA256: String(repeating: "b", count: 64),
            runs: [
                .init(startFrame: 0, endFrameExclusive: 2, pose: .rest),
                .init(startFrame: 2, endFrameExclusive: 4, pose: .small),
                .init(startFrame: 4, endFrameExclusive: 6, pose: .wide),
                .init(startFrame: 6, endFrameExclusive: 8, pose: .round),
                .init(startFrame: 8, endFrameExclusive: 10, pose: .teeth)
            ]
        )
        var cursor = 0

        XCTAssertEqual(track.pose(atFrame: 0, cursor: &cursor), .rest)
        XCTAssertEqual(cursor, 0)
        XCTAssertEqual(track.pose(atFrame: 5, cursor: &cursor), .wide)
        XCTAssertEqual(cursor, 2)
        XCTAssertEqual(track.pose(atFrame: 9, cursor: &cursor), .teeth)
        XCTAssertEqual(cursor, 4)
        XCTAssertEqual(track.pose(atFrame: 3, cursor: &cursor), .small)
        XCTAssertEqual(cursor, 1, "Backward/loop wrap sampling must binary-search")
        XCTAssertEqual(track.pose(atFrame: 10, cursor: &cursor), .rest)
        XCTAssertEqual(track.pose(atFrame: -1, cursor: &cursor), .rest)
    }

    func testDadAuthorityPresenceLoopWrapsOnActualPlaybackClock() {
        let sourceID = UUID()
        let origin = ContinuousClock.now
        let presence = dadPlaybackStart(
            sourceID: sourceID,
            role: .presenceLoop,
            fileName: "dad_breathing.wav",
            clockOrigin: origin
        )
        let track = dadTrack(
            for: presence.identity,
            framesPerSecond: 4,
            poses: [.rest, .small, .wide, .round]
        )
        var authority = dadAuthority(sourceID: sourceID)

        authority.receive(.started(presence))
        XCTAssertEqual(
            authority.trackDidBecomeReady(for: presence.identity, track: track),
            .attached
        )
        XCTAssertEqual(
            authority.activePose(now: origin.advanced(by: .milliseconds(250))),
            .small
        )
        XCTAssertEqual(
            authority.activePose(now: origin.advanced(by: .milliseconds(1_250))),
            .small,
            "Frame five must wrap to frame one of the four-frame presence loop"
        )
    }

    func testDadAuthorityDamageOverridesThenResumesCurrentPresencePhase() {
        let sourceID = UUID()
        let origin = ContinuousClock.now
        let presence = dadPlaybackStart(
            sourceID: sourceID,
            role: .presenceLoop,
            fileName: "dad_breathing.wav",
            clockOrigin: origin
        )
        let damage = dadPlaybackStart(
            sourceID: sourceID,
            role: .damageHit,
            fileName: "dad-damaged-01.wav",
            clockOrigin: origin.advanced(by: .seconds(1))
        )
        let presenceTrack = dadTrack(
            for: presence.identity,
            framesPerSecond: 4,
            poses: [.rest, .small, .wide, .round, .teeth, .round, .small, .wide]
        )
        let damageTrack = dadTrack(
            for: damage.identity,
            framesPerSecond: 4,
            poses: [.wide, .teeth, .wide, .teeth]
        )
        let sampleTime = origin.advanced(by: .milliseconds(1_250))
        var authority = dadAuthority(sourceID: sourceID)

        authority.receive(.started(presence))
        XCTAssertEqual(
            authority.trackDidBecomeReady(
                for: presence.identity,
                track: presenceTrack
            ),
            .attached
        )
        authority.receive(.started(damage))
        XCTAssertEqual(
            authority.trackDidBecomeReady(for: damage.identity, track: damageTrack),
            .attached
        )
        XCTAssertEqual(authority.activeIdentity, damage.identity)
        XCTAssertEqual(authority.activePose(now: sampleTime), .teeth)

        authority.receive(.completed(damage.identity))
        XCTAssertEqual(authority.activeIdentity, presence.identity)
        XCTAssertEqual(
            authority.activePose(now: sampleTime),
            .round,
            "Presence must resume at frame five, not restart at frame zero"
        )
    }

    func testDadAuthorityDeathIsTerminalAndHoldsClosedAfterCompletion() {
        let sourceID = UUID()
        let origin = ContinuousClock.now
        let presence = dadPlaybackStart(
            sourceID: sourceID,
            role: .presenceLoop,
            fileName: "dad_breathing.wav",
            clockOrigin: origin
        )
        let death = dadPlaybackStart(
            sourceID: sourceID,
            role: .death,
            fileName: "dad-death-01.wav",
            clockOrigin: origin
        )
        let postDeathDamage = dadPlaybackStart(
            sourceID: sourceID,
            role: .damageHit,
            fileName: "dad-damaged-01.wav",
            clockOrigin: origin.advanced(by: .seconds(1))
        )
        var authority = dadAuthority(sourceID: sourceID)

        authority.receive(.started(presence))
        XCTAssertEqual(
            authority.trackDidBecomeReady(
                for: presence.identity,
                track: dadTrack(for: presence.identity, poses: [.small])
            ),
            .attached
        )
        authority.receive(.started(death))
        XCTAssertEqual(
            authority.trackDidBecomeReady(
                for: death.identity,
                track: dadTrack(for: death.identity, poses: [.wide, .teeth])
            ),
            .attached
        )
        XCTAssertTrue(authority.deathIsTerminal)
        XCTAssertEqual(authority.activePose(now: origin), .wide)

        authority.receive(.completed(death.identity))
        XCTAssertNil(authority.activeIdentity)
        XCTAssertEqual(authority.activePose(now: origin), .rest)

        authority.receive(.started(postDeathDamage))
        XCTAssertNil(authority.activeIdentity)
        XCTAssertEqual(authority.activePose(now: origin.advanced(by: .seconds(1))), .rest)
    }

    func testDadAuthorityIgnoresStaleDamageAndDeathCompletions() {
        let sourceID = UUID()
        let origin = ContinuousClock.now
        let damageOne = dadPlaybackStart(
            sourceID: sourceID,
            role: .damageHit,
            fileName: "dad-damaged-01.wav",
            clockOrigin: origin
        )
        let damageTwo = dadPlaybackStart(
            sourceID: sourceID,
            role: .damageHit,
            fileName: "dad-damaged-02.wav",
            clockOrigin: origin
        )
        let deathOne = dadPlaybackStart(
            sourceID: sourceID,
            role: .death,
            fileName: "dad-death-01.wav",
            clockOrigin: origin
        )
        let deathTwo = dadPlaybackStart(
            sourceID: sourceID,
            role: .death,
            fileName: "dad-death-02.wav",
            clockOrigin: origin
        )
        var authority = dadAuthority(sourceID: sourceID)

        authority.receive(.started(damageOne))
        authority.receive(.started(damageTwo))
        XCTAssertEqual(authority.activeIdentity, damageTwo.identity)
        authority.receive(.completed(damageOne.identity))
        XCTAssertEqual(
            authority.activeIdentity,
            damageTwo.identity,
            "A replaced damage callback cannot clear the current damage vocal"
        )

        authority.receive(.started(deathOne))
        authority.receive(.started(deathTwo))
        XCTAssertEqual(authority.activeIdentity, deathTwo.identity)
        authority.receive(.completed(deathOne.identity))
        XCTAssertEqual(
            authority.activeIdentity,
            deathTwo.identity,
            "A replaced death callback cannot clear the current death vocal"
        )
        XCTAssertTrue(authority.deathIsTerminal)
    }

    func testDadAuthorityLateExactTrackAttachSamplesElapsedOnePointTwoFiveSeconds() {
        let sourceID = UUID()
        let origin = ContinuousClock.now
        let damage = dadPlaybackStart(
            sourceID: sourceID,
            role: .damageHit,
            fileName: "dad-damaged-03.wav",
            clockOrigin: origin
        )
        let track = dadTrack(
            for: damage.identity,
            framesPerSecond: 60,
            poses: Array(repeating: .wide, count: 75) +
                Array(repeating: .round, count: 25)
        )
        let lateJoinTime = origin.advanced(by: .milliseconds(1_250))
        var authority = dadAuthority(sourceID: sourceID)

        authority.receive(.started(damage))
        XCTAssertEqual(authority.activePose(now: lateJoinTime), .rest)
        XCTAssertEqual(
            authority.trackDidBecomeReady(for: damage.identity, track: track),
            .attached
        )
        XCTAssertEqual(
            authority.activePose(now: lateJoinTime),
            .round,
            "Late readiness must sample floor(1.25 * 60) = frame 75"
        )
        XCTAssertNotEqual(authority.activePose(now: lateJoinTime), .wide)
    }

    func testDadAuthorityRejectsWrongTrackAndInactivePlaybackIdentity() {
        let sourceID = UUID()
        let origin = ContinuousClock.now
        let active = dadPlaybackStart(
            sourceID: sourceID,
            role: .damageHit,
            fileName: "dad-damaged-01.wav",
            clockOrigin: origin
        )
        let wrongFile = dadPlaybackStart(
            sourceID: sourceID,
            role: .damageHit,
            fileName: "dad-damaged-02.wav",
            clockOrigin: origin
        )
        let staleSameAsset = dadPlaybackStart(
            sourceID: sourceID,
            role: .damageHit,
            fileName: active.identity.fileName,
            clockOrigin: origin
        )
        var authority = dadAuthority(sourceID: sourceID)

        authority.receive(.started(active))
        XCTAssertEqual(
            authority.trackDidBecomeReady(
                for: active.identity,
                track: dadTrack(for: wrongFile.identity, poses: [.wide])
            ),
            .mismatchedIdentity
        )
        XCTAssertEqual(authority.activePose(now: origin), .rest)
        XCTAssertEqual(
            authority.trackDidBecomeReady(
                for: staleSameAsset.identity,
                track: dadTrack(for: staleSameAsset.identity, poses: [.wide])
            ),
            .inactivePlayback,
            "Matching asset fields cannot bypass the exact playback identity"
        )
        XCTAssertEqual(authority.activeIdentity, active.identity)
    }

    func testVocalAuthorityStateIsGenericAcrossEverySupportedCharacter() throws {
        let origin = ContinuousClock.now
        for profile in CharacterVocalBlendShapeProfile.supported {
            let entry = try XCTUnwrap(
                CharacterVocalAudioInventory.ordered(
                    characterID: profile.characterID
                ).first { $0.role == .damageHit }
            )
            let sourceID = UUID()
            let start = CharacterVocalPlaybackStart(
                identity: .init(
                    playbackID: UUID(),
                    sourceID: sourceID,
                    characterID: profile.characterID,
                    archetype: profile.archetype,
                    role: entry.role,
                    fileName: entry.fileName,
                    isLooping: false
                ),
                clockOrigin: origin,
                expectedDurationSeconds: 1
            )
            var authority = CharacterVocalAuthorityState(
                sourceID: sourceID,
                characterID: profile.characterID,
                archetype: profile.archetype,
                audioRoles: CharacterVocalAudioInventory.animatedRoles
            )

            authority.receive(.started(start))
            XCTAssertEqual(
                authority.trackDidBecomeReady(
                    for: start.identity,
                    track: dadTrack(for: start.identity, poses: [.wide])
                ),
                .attached,
                profile.characterID
            )
            XCTAssertEqual(authority.activeIdentity, start.identity, profile.characterID)
            XCTAssertEqual(authority.activePose(now: origin), .wide, profile.characterID)
        }
    }

    func testVisemeTrackIdentityRejectsWrongAudibleAssetFields() {
        let sourceID = UUID()
        let identity = CharacterVocalVisemeTrackIdentity(
            characterID: "dad",
            role: .damageHit,
            audioFile: "dad-damaged-01.wav",
            audioSHA256: String(repeating: "c", count: 64),
            looping: false
        )
        func playback(
            characterID: String = "dad",
            role: CharacterVocalRole = .damageHit,
            fileName: String = "dad-damaged-01.wav",
            looping: Bool = false
        ) -> CharacterVocalPlaybackIdentity {
            .init(
                playbackID: UUID(),
                sourceID: sourceID,
                characterID: characterID,
                archetype: characterID == "dad" ? .dad : .grandma,
                role: role,
                fileName: fileName,
                isLooping: looping
            )
        }

        XCTAssertTrue(identity.matches(playback()))
        XCTAssertFalse(identity.matches(playback(characterID: "grandma")))
        XCTAssertFalse(identity.matches(playback(role: .death)))
        XCTAssertFalse(identity.matches(playback(fileName: "dad-damaged-02.wav")))
        XCTAssertFalse(identity.matches(playback(looping: true)))
    }

    func testProductionCharacterPerformanceHasNoRuntimeAudioAnalysis() throws {
        let root = try repositoryRoot()
        let characterPerformanceDirectory = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterPerformance"
        )
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: characterPerformanceDirectory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        let productionFiles = enumerator.compactMap { $0 as? URL }.filter {
            ["swift", "metal"].contains($0.pathExtension)
        }
        let productionSource = try productionFiles.map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")
        let forbidden = [
            "TuringGeneratedSpeechAnalyzer",
            "TuringSpeechAmplitudeEnvelope",
            "compatibilityDSP",
            "AVAudioFile",
            "AVAudioConverter",
            "floatChannelData",
            "processedAudio",
            "normalizedEnergy",
            "zeroCrossing",
            "RMS",
            "decibels",
            "amplitude",
            "PCM"
        ]
        for token in forbidden {
            XCTAssertFalse(
                productionSource.contains(token),
                "Production CharacterPerformance contains forbidden token: \(token)"
            )
        }
        XCTAssertTrue(productionSource.contains("CharacterVocalVisemeTrackStore"))
        XCTAssertTrue(productionSource.contains("pocketsphinxAllPhone"))

        let vocalDirectory = characterPerformanceDirectory.appendingPathComponent(
            "VocalBlendShape"
        )
        let routing = try String(
            contentsOf: vocalDirectory.appendingPathComponent(
                "CharacterVocalPoseTrackStore.swift"
            ),
            encoding: .utf8
        )
        let prepare = try functionBody(named: "prepare", in: routing)
        XCTAssertTrue(prepare.contains("CharacterVocalBlendShapeProfile.resolve("))
        XCTAssertTrue(prepare.contains("authoredStore.track(for: asset)"))
        XCTAssertFalse(prepare.contains("asset.characterID == \"dad\""))
        XCTAssertFalse(prepare.contains("compatibilityStore"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: characterPerformanceDirectory.appendingPathComponent(
                    "Compatibility/CharacterVocalCompatibilityPoseTrackStore.swift"
                ).path
            )
        )
        let authoredStore = try String(
            contentsOf: vocalDirectory.appendingPathComponent(
                "CharacterVocalVisemeTrackStore.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            authoredStore.contains(
                "manifest.characterID == configuration.characterID"
            ),
            "Shared breathing audio must not allow a cross-wired character manifest"
        )
    }

    func testAuthoredDadResourcesExistAndMatchLockedHashes() throws {
        let root = try repositoryRoot()
        let descriptor = try productionDescriptor()
        let sourceAssetURL = root.appendingPathComponent("dad_biped.usdz")
        let payloadURL = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/" +
                (try XCTUnwrap(descriptor.offsetPayloadResourcePath))
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAssetURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertEqual(try sha256(sourceAssetURL), descriptor.sourceAssetSHA256)
        XCTAssertEqual(
            try sha256(payloadURL),
            try XCTUnwrap(descriptor.offsetPayloadSHA256)
        )

        for entry in DadVocalAudioInventory.ordered {
            let relativePath = entry.role == .presenceLoop
                ? entry.fileName
                : "Gravitas Plague/Gravitas Plague/Audio/\(entry.fileName)"
            let url = root.appendingPathComponent(relativePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Missing authored Dad audio: \(relativePath)"
            )
            XCTAssertEqual(
                try sha256(url),
                entry.sha256,
                "Authored Dad audio changed: \(entry.fileName)"
            )
        }

        let breathingURL = root.appendingPathComponent("dad_breathing.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: breathingURL.path))
        XCTAssertEqual(
            try sha256(breathingURL),
            "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"
        )

        try assertBundledDadResourcesWhenAvailable(descriptor: descriptor)
    }

    func testOffsetPayloadHasLockedMagicAndCounts() throws {
        let descriptor = try productionDescriptor()
        let data = try productionPayloadData(descriptor: descriptor)

        XCTAssertEqual(data.prefix(8), Data("GRDADV1\0".utf8))

        let payload = try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: try XCTUnwrap(descriptor.offsetPayloadMeshCount),
            expectedRecordCount: try XCTUnwrap(descriptor.offsetPayloadRecordCount)
        )
        XCTAssertEqual(payload.meshes.count, 1)
        let mesh = try XCTUnwrap(payload.meshes.first)
        XCTAssertEqual(mesh.sourcePrimPath, "/root/Armature/char1/char1")
        XCTAssertEqual(mesh.sourcePointCount, 144_525)
        XCTAssertEqual(
            mesh.records.count,
            try XCTUnwrap(descriptor.offsetPayloadRecordCount)
        )
        XCTAssertFalse(mesh.records.isEmpty)
        XCTAssertEqual(
            mesh.records.map(\.pointIndex),
            mesh.records.map(\.pointIndex).sorted()
        )
        XCTAssertTrue(mesh.records.allSatisfy {
            $0.pointIndex >= 0 &&
                $0.pointIndex < mesh.sourcePointCount &&
                simd_length_squared($0.offset) > 0
        })
    }

    func testOffsetPayloadRejectsWrongMagicAndExpectedCounts() throws {
        let descriptor = try productionDescriptor()
        let data = try productionPayloadData(descriptor: descriptor)
        let meshCount = try XCTUnwrap(descriptor.offsetPayloadMeshCount)
        let recordCount = try XCTUnwrap(descriptor.offsetPayloadRecordCount)

        var badMagic = data
        badMagic[badMagic.startIndex] = 0
        XCTAssertThrowsError(try SingleBlendShapeOffsetPayload(
            data: badMagic,
            expectedMeshCount: meshCount,
            expectedRecordCount: recordCount
        )) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidOffsetPayload("magic")
            )
        }

        XCTAssertThrowsError(try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: meshCount + 1,
            expectedRecordCount: recordCount
        )) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidOffsetPayload("meshCount")
            )
        }

        XCTAssertThrowsError(try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: meshCount,
            expectedRecordCount: recordCount + 1
        )) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidOffsetPayload("length")
            )
        }
    }

    @MainActor
    func testNativeOffsetValidationUsesOriginalVertexMap() throws {
        let close = SIMD3<Float>(0.1, -0.2, 0.3)
        let source = SingleBlendShapeOffsetPayload.Mesh(
            sourcePrimPath: "/root/Armature/char1/char1",
            sourcePointCount: 3,
            records: [
                .init(
                    pointIndex: 1,
                    basePosition: SIMD3<Float>(1, 2, 3),
                    offset: close
                )
            ]
        )
        let result = try SingleBlendShapeMeshImportValidator.validateNativeOffsets(
            source: source,
            importedPositions: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 2, 3),
                SIMD3<Float>(1, 2, 3),
                SIMD3<Float>(8, 9, 10)
            ],
            originalPartVertexIndices: [0, 1, 1, 2],
            nativeOffsets: [.zero, close, close, .zero],
            registrationTolerance: 0.000_002
        )

        XCTAssertEqual(result.matchedSourceRecordCount, 1)
        XCTAssertEqual(result.matchedRenderVertexCount, 2)
        XCTAssertEqual(result.splitRenderVertexCount, 1)
        XCTAssertEqual(result.maximumNativeOffset, simd_length(close))
    }

    @MainActor
    func testNativeOffsetValidationRejectsWrongMappedDelta() {
        let close = SIMD3<Float>(0, 0.1, 0)
        let source = SingleBlendShapeOffsetPayload.Mesh(
            sourcePrimPath: "/root/Armature/char1/char1",
            sourcePointCount: 2,
            records: [
                .init(
                    pointIndex: 1,
                    basePosition: SIMD3<Float>(1, 0, 0),
                    offset: close
                )
            ]
        )

        XCTAssertThrowsError(try SingleBlendShapeMeshImportValidator.validateNativeOffsets(
            source: source,
            importedPositions: [.zero, SIMD3<Float>(1, 0, 0)],
            originalPartVertexIndices: [0, 1],
            nativeOffsets: [close, .zero],
            registrationTolerance: 0.000_002
        ))
    }

    func testProductionDeformerIsGPUOnDemandAndRunsBeforeSkinning() throws {
        let deformer = CharacterVocalDenseOffsetDeformer(
            stateID: UUID(),
            weight: 0.5,
            vertexCount: 172_668
        )

        XCTAssertEqual(CharacterVocalDenseOffsetDeformer.mode, .gpu)
        XCTAssertEqual(deformer.mode, .gpu)
        XCTAssertEqual(deformer.options.cadence, .onDemand)
        XCTAssertEqual(deformer.options.inputSpec, .positions)
        XCTAssertEqual(deformer.options.outputSpec, .positions)
        XCTAssertEqual(deformer.vertexCount, 172_668)

        let geometryURL = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/" +
                "VocalBlendShape/CharacterVocalBlendShapeGeometry.swift"
        )
        let geometry = try String(contentsOf: geometryURL, encoding: .utf8)
        XCTAssertFalse(geometry.contains("mesh.replace("))
        XCTAssertFalse(geometry.contains("replace(with:"))

        let custom = try XCTUnwrap(
            geometry.range(of: "CharacterVocalDenseOffsetDeformer(")
        )
        let blend = try XCTUnwrap(
            geometry.range(of: "BlendShapeDeformer()", range: custom.upperBound..<geometry.endIndex)
        )
        let skin = try XCTUnwrap(
            geometry.range(
                of: "SkinningDeformer(skinsTangentFrame: true)",
                range: blend.upperBound..<geometry.endIndex
            )
        )
        let bounds = try XCTUnwrap(
            geometry.range(
                of: "BoundingBoxCalculator()",
                range: skin.upperBound..<geometry.endIndex
            )
        )
        XCTAssertLessThan(custom.lowerBound, blend.lowerBound)
        XCTAssertLessThan(blend.lowerBound, skin.lowerBound)
        XCTAssertLessThan(skin.lowerBound, bounds.lowerBound)

        let metalURL = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/" +
                "VocalBlendShape/CharacterVocalBlendShapeDeformer.metal"
        )
        let metal = try String(contentsOf: metalURL, encoding: .utf8)
        XCTAssertTrue(metal.contains("kernel void characterVocalApplyDenseOffsets"))
        XCTAssertTrue(metal.contains("position + delta"))
    }

    func testRenderBoundsPolicyAddsConservativeModelSpaceMargin() {
        let bounds = BoundingBox(
            min: SIMD3<Float>(-50, -100, -25),
            max: SIMD3<Float>(50, 100, 25)
        )

        XCTAssertEqual(
            CharacterVocalRenderBoundsPolicy.resolvedMargin(
                preserving: 0,
                meshBounds: bounds
            ),
            40,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            CharacterVocalRenderBoundsPolicy.resolvedMargin(
                preserving: 30,
                meshBounds: bounds
            ),
            30,
            accuracy: 0.000_001
        )
    }

    func testResponseUsesDirectionalAndCrossingHalfLives() throws {
        let response = CharacterVocalBlendShapeResponse(
            try productionDescriptor().response
        )
        let deltaTime: Float = 0.01
        let increasing = response.step(
            current: 0,
            target: 1,
            deltaTime: deltaTime
        )
        let decreasing = response.step(
            current: 1,
            target: 0,
            deltaTime: deltaTime
        )
        XCTAssertEqual(
            increasing,
            1 - exp2(-deltaTime / 0.05),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            decreasing,
            exp2(-deltaTime / 0.03),
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(1 - decreasing, increasing)

        let crossingUp = response.step(
            current: 0,
            target: 0.5,
            deltaTime: deltaTime
        )
        let crossingDown = response.step(
            current: 1,
            target: 0.5,
            deltaTime: deltaTime
        )
        let crossingAlpha: Float = 1 - exp2(-deltaTime / 0.035)
        XCTAssertEqual(crossingUp, 0.5 * crossingAlpha, accuracy: 0.000_001)
        XCTAssertEqual(
            crossingDown,
            1 - 0.5 * crossingAlpha,
            accuracy: 0.000_001
        )
    }

    func testResponseCapsDeltaAndConvergesWithoutOvershoot() throws {
        let response = CharacterVocalBlendShapeResponse(
            try productionDescriptor().response
        )
        XCTAssertEqual(
            response.step(current: 0.25, target: 1, deltaTime: 0),
            0.25
        )
        XCTAssertEqual(
            response.step(current: 0.25, target: 1, deltaTime: -1),
            0.25
        )
        XCTAssertEqual(
            response.step(current: 0.25, target: 1, deltaTime: 5),
            response.step(current: 0.25, target: 1, deltaTime: 0.05),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            response.step(current: 0.999_9, target: 1, deltaTime: 1.0 / 60.0),
            1
        )

        try assertConvergence(
            response: response,
            initial: 0,
            target: 1,
            direction: .increasing
        )
        try assertConvergence(
            response: response,
            initial: 1,
            target: 0,
            direction: .decreasing
        )
        try assertConvergence(
            response: response,
            initial: 0,
            target: 0.5,
            direction: .increasing
        )
        try assertConvergence(
            response: response,
            initial: 1,
            target: 0.5,
            direction: .decreasing
        )
        try assertConvergence(
            response: response,
            initial: 0.5,
            target: 0,
            direction: .decreasing
        )
    }

    @MainActor
    func testEventHubPublishesToSubscribersAndCancelIsIsolated() {
        let hub = CharacterVocalPlaybackEventHub()
        let identity = CharacterVocalPlaybackIdentity(
            playbackID: UUID(),
            sourceID: UUID(),
            characterID: "dad",
            archetype: .dad,
            role: .damageHit,
            fileName: "dad-damaged-01.wav",
            isLooping: false
        )
        let start = CharacterVocalPlaybackStart(
            identity: identity,
            clockOrigin: .now,
            expectedDurationSeconds: 0.75
        )
        var firstEvents: [CharacterVocalPlaybackEvent] = []
        var secondEvents: [CharacterVocalPlaybackEvent] = []
        let first = hub.subscribe { firstEvents.append($0) }
        let second = hub.subscribe { secondEvents.append($0) }

        hub.publish(.started(start))
        XCTAssertEqual(firstEvents, [.started(start)])
        XCTAssertEqual(secondEvents, [.started(start)])
        XCTAssertEqual(firstEvents.first?.sourceID, identity.sourceID)

        first.cancel()
        first.cancel()
        hub.publish(.completed(identity))

        XCTAssertEqual(firstEvents, [.started(start)])
        XCTAssertEqual(secondEvents, [.started(start), .completed(identity)])
        withExtendedLifetime(second) {}
    }

    func testFaceHitPathsStayOutOfVocalEventHub() throws {
        let source = try audioControllerSource()
        let faceHitFunctions = [
            "playConfirmedCharacterFaceHitSound",
            "playFacePunchContactSoundIfNeeded",
            "playConcurrentCharacterSpatialOneShot"
        ]

        for name in faceHitFunctions {
            let body = try functionBody(named: name, in: source)
            XCTAssertFalse(
                body.contains("characterVocalPlaybackEventHub.publish"),
                "\(name) must not publish vocal playback events"
            )
            XCTAssertFalse(
                body.contains("CharacterVocalPlaybackIdentity("),
                "\(name) must not manufacture vocal playback identity"
            )
        }
    }

    func testPresenceAndReplacingVocalPathsPublishLifecycleEvents() throws {
        let source = try audioControllerSource()
        let presence = try functionBody(named: "startCharacterLoopAudio", in: source)
        XCTAssertTrue(presence.contains("role: .presenceLoop"))
        XCTAssertTrue(presence.contains("fileName: loopFile.fullName"))
        XCTAssertTrue(presence.contains("isLooping: true"))
        XCTAssertTrue(presence.contains("expectedDurationSeconds: nil"))
        let immediatePlay = try XCTUnwrap(
            presence.range(of: "source.headEntity.playAudio(loopResource)")
        )
        let immediateClock = try XCTUnwrap(
            presence.range(
                of: "let clockOrigin = ContinuousClock.now",
                range: immediatePlay.upperBound..<presence.endIndex
            )
        )
        let immediatePublish = try XCTUnwrap(
            presence.range(
                of: "characterVocalPlaybackEventHub.publish(.started",
                range: immediateClock.upperBound..<presence.endIndex
            )
        )
        XCTAssertLessThan(immediatePlay.lowerBound, immediateClock.lowerBound)
        XCTAssertLessThan(immediateClock.lowerBound, immediatePublish.lowerBound)
        XCTAssertEqual(
            presence.components(
                separatedBy: "source.headEntity.playAudio(loopResource)"
            ).count - 1,
            2
        )
        XCTAssertEqual(
            presence.components(
                separatedBy: "let clockOrigin = ContinuousClock.now"
            ).count - 1,
            2
        )
        let delayedPlay = try XCTUnwrap(
            presence.range(
                of: "source.headEntity.playAudio(loopResource)",
                range: immediatePlay.upperBound..<presence.endIndex
            )
        )
        let delayedClock = try XCTUnwrap(
            presence.range(
                of: "let clockOrigin = ContinuousClock.now",
                range: delayedPlay.upperBound..<presence.endIndex
            )
        )
        let delayedPublish = try XCTUnwrap(
            presence.range(
                of: "characterVocalPlaybackEventHub.publish(.started",
                range: delayedClock.upperBound..<presence.endIndex
            )
        )
        XCTAssertLessThan(delayedPlay.lowerBound, delayedClock.lowerBound)
        XCTAssertLessThan(delayedClock.lowerBound, delayedPublish.lowerBound)

        let replacing = try functionBody(
            named: "playReplacingCharacterVocal",
            in: source
        )
        XCTAssertTrue(replacing.contains("CharacterVocalRole(rawValue: role)"))
        XCTAssertTrue(replacing.contains("fileName: file.fullName"))
        XCTAssertTrue(replacing.contains("isLooping: false"))
        XCTAssertTrue(replacing.contains(".cancelled(previous.identity"))
        let vocalPlay = try XCTUnwrap(
            replacing.range(of: "source.headEntity.playAudio(resource)")
        )
        let vocalClock = try XCTUnwrap(
            replacing.range(
                of: "let clockOrigin = ContinuousClock.now",
                range: vocalPlay.upperBound..<replacing.endIndex
            )
        )
        let activeOwnership = try XCTUnwrap(
            replacing.range(
                of: "activeCharacterVocalBySourceID[sourceID] =",
                range: vocalClock.upperBound..<replacing.endIndex
            )
        )
        let completionHandler = try XCTUnwrap(
            replacing.range(
                of: "controller.completionHandler =",
                range: activeOwnership.upperBound..<replacing.endIndex
            )
        )
        let vocalPublish = try XCTUnwrap(
            replacing.range(
                of: "characterVocalPlaybackEventHub.publish(.started",
                range: completionHandler.upperBound..<replacing.endIndex
            )
        )
        XCTAssertLessThan(vocalPlay.lowerBound, vocalClock.lowerBound)
        XCTAssertLessThan(vocalClock.lowerBound, activeOwnership.lowerBound)
        XCTAssertLessThan(activeOwnership.lowerBound, completionHandler.lowerBound)
        XCTAssertLessThan(completionHandler.lowerBound, vocalPublish.lowerBound)

        let completion = try functionBody(named: "completeCharacterVocal", in: source)
        let exactIdentityGuard = try XCTUnwrap(
            completion.range(of: "active.identity == identity")
        )
        let completionPublish = try XCTUnwrap(
            completion.range(of: "publish(.completed(identity))")
        )
        XCTAssertLessThan(
            exactIdentityGuard.lowerBound,
            completionPublish.lowerBound,
            "A stale callback must not complete a replacement playback"
        )
    }

    func testDadRuntimeUsesActualClockAndTerminalPresenceOneShotArbitration() throws {
        let source = try dadRuntimeSource()
        let controllerReceive = try functionBody(named: "receive", in: source)
        XCTAssertTrue(controllerReceive.contains("drivesAnimation("))
        XCTAssertTrue(source.contains("private var presenceLoop"))
        XCTAssertTrue(source.contains("private var oneShot"))
        XCTAssertTrue(source.contains("private(set) var deathIsTerminal = false"))
        XCTAssertTrue(controllerReceive.contains("presenceLoop = .init"))
        XCTAssertTrue(controllerReceive.contains("oneShot = .init"))
        XCTAssertTrue(controllerReceive.contains("guard !deathIsTerminal"))
        XCTAssertTrue(controllerReceive.contains("deathIsTerminal = true"))
        XCTAssertFalse(controllerReceive.contains("deathIsTerminal = false"))
        XCTAssertTrue(
            controllerReceive.contains("presenceLoop?.start.identity == identity")
        )
        XCTAssertEqual(
            controllerReceive.components(
                separatedBy: "presenceLoop?.start.identity == identity"
            ).count - 1,
            2
        )
        XCTAssertTrue(
            controllerReceive.contains("oneShot?.start.identity == identity")
        )
        XCTAssertEqual(
            controllerReceive.components(
                separatedBy: "oneShot?.start.identity == identity"
            ).count - 1,
            2
        )

        let activePose = try functionBody(named: "activePose", in: source)
        let oneShotAuthority = try XCTUnwrap(
            activePose.range(of: "if var oneShot")
        )
        let terminalAuthority = try XCTUnwrap(
            activePose.range(of: "if deathIsTerminal")
        )
        let presenceAuthority = try XCTUnwrap(
            activePose.range(of: "if var presenceLoop")
        )
        XCTAssertLessThan(oneShotAuthority.lowerBound, terminalAuthority.lowerBound)
        XCTAssertLessThan(terminalAuthority.lowerBound, presenceAuthority.lowerBound)
        XCTAssertTrue(activePose.contains("sample(&oneShot, now: now, loops: false)"))
        XCTAssertTrue(activePose.contains("sample(&presenceLoop, now: now, loops: true)"))

        let sample = try functionBody(named: "sample", in: source)
        XCTAssertTrue(
            sample.contains("playback.start.clockOrigin.duration(to: now)")
        )
        XCTAssertTrue(sample.contains("rawFrame % track.frameCount"))
        XCTAssertTrue(
            sample.contains("guard rawFrame < track.frameCount else { return .rest }")
        )
        XCTAssertTrue(
            sample.contains("track.pose(atFrame: frame, cursor: &playback.runCursor)")
        )
        XCTAssertFalse(sample.contains("Date"))
        XCTAssertFalse(sample.contains("CACurrentMediaTime"))

        let attach = try functionBody(named: "trackDidBecomeReady", in: source)
        XCTAssertTrue(attach.contains("track.identity.matches(identity)"))
        XCTAssertTrue(attach.contains("presenceLoop?.start.identity == identity"))
        XCTAssertTrue(attach.contains("oneShot?.start.identity == identity"))
        XCTAssertTrue(attach.contains("runCursor = 0"))

        let clear = try functionBody(named: "clear", in: source)
        XCTAssertTrue(clear.contains("presenceLoop = nil"))
        XCTAssertTrue(clear.contains("oneShot = nil"))
        XCTAssertTrue(clear.contains("deathIsTerminal = false"))
        let reset = try functionBody(named: "reset", in: source)
        XCTAssertTrue(reset.contains("authority.clear()"))
        XCTAssertTrue(reset.contains("descriptor.fallbackWeight"))

        let requestTrack = try functionBody(named: "requestTrack", in: source)
        XCTAssertTrue(requestTrack.contains("drivesAnimation("))
        XCTAssertTrue(requestTrack.contains("CharacterVocalAudioInventory.asset(for: start)"))
        XCTAssertTrue(source.contains("let requestToken: UUID"))
        XCTAssertTrue(requestTrack.contains("let requestToken = UUID()"))
        XCTAssertTrue(
            requestTrack.contains(
                "trackJoinTasks[playbackID]?.requestToken == requestToken"
            )
        )
        XCTAssertTrue(
            requestTrack.contains("trackJoinTasks.removeValue(forKey: playbackID)")
        )
        XCTAssertTrue(requestTrack.contains("requestToken: requestToken"))
        XCTAssertTrue(requestTrack.contains("for: start.identity"))
        XCTAssertFalse(
            source.contains("buffered.count == 16"),
            "Registration must not discard an earlier presence-loop start"
        )
        XCTAssertFalse(
            source.contains("buffered.removeFirst()"),
            "Pending exact audio history must survive manifest readiness"
        )

        let prewarm = try functionBody(named: "startPrewarmIfNeeded", in: source)
        XCTAssertTrue(
            prewarm.contains("CharacterVocalAudioInventory.assets(")
        )
        XCTAssertTrue(prewarm.contains("characterID: characterID"))
        XCTAssertEqual(DadVocalAudioInventory.ordered.count, 9)
    }

    func testAllSupportedCharactersUseAuthoredTrackPreparation() throws {
        let root = try repositoryRoot()
        let storeSource = try String(
            contentsOf: root.appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/CharacterPerformance/" +
                    "VocalBlendShape/CharacterVocalPoseTrackStore.swift"
            ),
            encoding: .utf8
        )
        let orderedInventory = try functionBody(named: "ordered", in: storeSource)
        for characterID in ["dad", "grandma", "spouse", "biker", "neighbor"] {
            XCTAssertTrue(
                orderedInventory.contains("case \"\(characterID)\""),
                "Authored inventory disappeared for \(characterID)"
            )
            XCTAssertEqual(
                CharacterVocalAudioInventory.ordered(
                    characterID: characterID
                ).count,
                9
            )
        }

        let prepare = try functionBody(named: "prepare", in: storeSource)
        XCTAssertTrue(prepare.contains("CharacterVocalBlendShapeProfile.resolve("))
        XCTAssertTrue(prepare.contains("authoredStore.track(for: asset)"))
        XCTAssertFalse(prepare.contains("compatibilityStore"))
        XCTAssertFalse(prepare.contains("asset.characterID == \"dad\""))
    }

    func testDadWindowAndHordePortalRegisterBreathingDrivenVisuals() throws {
        let source = try immersiveCoordinatorSource()
        let dadWindowStart = try XCTUnwrap(
            source.range(of: "let dadWindow = Chapter01DadWindowCoordinator(")
        )
        let dadWindowEnd = try XCTUnwrap(
            source.range(
                of: "let postRobotInteractions",
                range: dadWindowStart.upperBound..<source.endIndex
            )
        )
        let dadWindow = String(
            source[dadWindowStart.lowerBound..<dadWindowEnd.lowerBound]
        )
        XCTAssertTrue(dadWindow.contains("onDadRuntimePrepared:"))
        XCTAssertTrue(dadWindow.contains("attachHostAudioSource("))
        XCTAssertTrue(dadWindow.contains("hostRootEntity: controller.rootEntity"))
        XCTAssertTrue(dadWindow.contains("archetype: .dad"))
        XCTAssertTrue(dadWindow.contains("headAudioEntity: controller.characterAudioEmitter"))
        XCTAssertTrue(dadWindow.contains("breathingStartDelay: 0"))
        XCTAssertTrue(dadWindow.contains("onDadRuntimeReleased:"))
        XCTAssertTrue(dadWindow.contains("stopHostAudioSource(id: sourceID)"))

        let windowCoordinator = try dadWindowCoordinatorSource()
        let windowRun = try functionBody(named: "run", in: windowCoordinator)
        let detach = try XCTUnwrap(
            windowRun.range(of: "detachDadAudioSource(reason:")
        )
        let release = try XCTUnwrap(
            windowRun.range(of: "runtime.lease.release(")
        )
        XCTAssertLessThan(detach.lowerBound, release.lowerBound)
        XCTAssertTrue(
            try functionBody(named: "cleanup", in: windowCoordinator)
                .contains("detachDadAudioSource(reason: reason)")
        )

        let hordeIngress = try functionBody(
            named: "registerHordeEnemyForInstancedPortalIngress",
            in: source
        )
        XCTAssertTrue(
            hordeIngress.contains(
                "CharacterVocalBlendShapeProfile.resolve(archetype: archetype) != nil"
            )
        )
        XCTAssertFalse(hordeIngress.contains("if archetype == .dad"))
        XCTAssertTrue(hordeIngress.contains("attachHostAudioSource("))
        XCTAssertTrue(hordeIngress.contains("hostRootEntity: controller.rootEntity"))
        XCTAssertTrue(
            hordeIngress.contains(
                "portalMirrorRootEntity: ingress.portalMirrorRootEntity"
            )
        )
        XCTAssertTrue(hordeIngress.contains("breathingStartDelay: 0"))

        let reveal = try functionBody(
            named: "updatePortalIngressControllers",
            in: source
        )
        XCTAssertTrue(
            reveal.contains(
                "if !audioController.hasActiveCharacterPresenceLoop(id: enemyID)"
            )
        )
        XCTAssertFalse(reveal.contains("controller.archetype != .dad"))
        let failedCleanup = try XCTUnwrap(
            reveal.range(of: "for enemyID in failedIDs")
        )
        let failedCleanupBody = String(reveal[failedCleanup.lowerBound...])
        XCTAssertTrue(
            failedCleanupBody.contains(
                "audioController.stopHostAudioSource(id: enemyID)"
            )
        )
        XCTAssertLessThan(
            try XCTUnwrap(
                failedCleanupBody.range(
                    of: "audioController.stopHostAudioSource(id: enemyID)"
                )
            ).lowerBound,
            try XCTUnwrap(
                failedCleanupBody.range(of: "portal_ingress_failed")
            ).lowerBound
        )
    }

    private enum Direction {
        case increasing
        case decreasing
    }

    private func dadAuthority(sourceID: UUID) -> CharacterVocalAuthorityState {
        CharacterVocalAuthorityState(
            sourceID: sourceID,
            characterID: "dad",
            archetype: .dad,
            audioRoles: [.presenceLoop, .damageHit, .death]
        )
    }

    private func dadPlaybackStart(
        sourceID: UUID,
        role: CharacterVocalRole,
        fileName: String,
        clockOrigin: ContinuousClock.Instant
    ) -> CharacterVocalPlaybackStart {
        .init(
            identity: .init(
                playbackID: UUID(),
                sourceID: sourceID,
                characterID: "dad",
                archetype: .dad,
                role: role,
                fileName: fileName,
                isLooping: role == .presenceLoop
            ),
            clockOrigin: clockOrigin,
            expectedDurationSeconds: role == .presenceLoop ? nil : 5
        )
    }

    private func dadTrack(
        for identity: CharacterVocalPlaybackIdentity,
        framesPerSecond: Int = 60,
        poses: [MindEyeMouthPose]
    ) -> CharacterVocalVisemeTrack {
        CharacterVocalVisemeTrack(
            trackID: "test.\(identity.playbackID.uuidString)",
            identity: .init(
                characterID: identity.characterID,
                role: identity.role,
                audioFile: identity.fileName,
                audioSHA256: String(repeating: "a", count: 64),
                looping: identity.isLooping
            ),
            sampleRate: 48_000,
            sampleCount: poses.count * max(1, 48_000 / framesPerSecond),
            framesPerSecond: framesPerSecond,
            frameCount: poses.count,
            runsSHA256: String(repeating: "b", count: 64),
            runs: ContiguousArray(
                poses.enumerated().map { index, pose in
                    .init(
                        startFrame: index,
                        endFrameExclusive: index + 1,
                        pose: pose
                    )
                }
            )
        )
    }

    private func assertConvergence(
        response: CharacterVocalBlendShapeResponse,
        initial: Float,
        target: Float,
        direction: Direction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var value = initial
        for _ in 0..<240 {
            let next = response.step(
                current: value,
                target: target,
                deltaTime: 1.0 / 60.0
            )
            switch direction {
            case .increasing:
                XCTAssertGreaterThanOrEqual(next, value, file: file, line: line)
                XCTAssertLessThanOrEqual(next, target, file: file, line: line)
            case .decreasing:
                XCTAssertLessThanOrEqual(next, value, file: file, line: line)
                XCTAssertGreaterThanOrEqual(next, target, file: file, line: line)
            }
            XCTAssertTrue(next.isFinite, file: file, line: line)
            value = next
        }
        XCTAssertEqual(
            value,
            target,
            accuracy: response.assignmentEpsilon,
            file: file,
            line: line
        )
    }

    private func productionDescriptor() throws -> CharacterVocalBlendShapeDescriptor {
        try JSONDecoder().decode(
            CharacterVocalBlendShapeDescriptor.self,
            from: productionDescriptorData()
        )
    }

    private func productionDescriptorData() throws -> Data {
        try Data(contentsOf: try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/" +
                "FacialPerformance/dad_infected_vocal_blendshape.json"
        ))
    }

    private func productionPayloadData(
        descriptor: CharacterVocalBlendShapeDescriptor
    ) throws -> Data {
        let path = try XCTUnwrap(descriptor.offsetPayloadResourcePath)
        return try Data(contentsOf: try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/\(path)"
        ))
    }

    private func mutatedProductionDescriptor(
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws -> CharacterVocalBlendShapeDescriptor {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: productionDescriptorData()
            ) as? [String: Any]
        )
        try mutate(&object)
        return try JSONDecoder().decode(
            CharacterVocalBlendShapeDescriptor.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func dadCharacterManifestAudio() throws -> [String: Any] {
        let manifestURL = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/" +
                "Characters/dad.character.json"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: manifestURL)
            ) as? [String: Any]
        )
        return try XCTUnwrap(object["audio"] as? [String: Any])
    }

    private func soundFileNames(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).compactMap { $0["file"] as? String }
    }

    private func assertBundledDadResourcesWhenAvailable(
        descriptor: CharacterVocalBlendShapeDescriptor
    ) throws {
        let bundle = Bundle.main
        if let url = bundle.url(
            forResource: "dad_infected_vocal_blendshape",
            withExtension: "json",
            subdirectory: "CharacterLibrary/FacialPerformance"
        ) ?? bundle.url(
            forResource: "dad_infected_vocal_blendshape",
            withExtension: "json"
        ) {
            let bundled = try JSONDecoder().decode(
                CharacterVocalBlendShapeDescriptor.self,
                from: Data(contentsOf: url)
            )
            XCTAssertEqual(bundled, descriptor)
        }

        if let url = bundle.url(forResource: "dad_biped", withExtension: "usdz") {
            XCTAssertEqual(try sha256(url), descriptor.sourceAssetSHA256)
        }

        if let url = bundle.url(
            forResource: "dad_infected_vocal_blendshape_offsets",
            withExtension: "bin",
            subdirectory: "CharacterLibrary/FacialPerformance"
        ) ?? bundle.url(
            forResource: "dad_infected_vocal_blendshape_offsets",
            withExtension: "bin"
        ) {
            XCTAssertEqual(
                try sha256(url),
                try XCTUnwrap(descriptor.offsetPayloadSHA256)
            )
        }

        let bundledAudio = DadVocalAudioInventory.assets(bundle: bundle)
        if !bundledAudio.isEmpty {
            XCTAssertEqual(bundledAudio.count, DadVocalAudioInventory.ordered.count)
            for asset in bundledAudio {
                XCTAssertEqual(try sha256(asset.url), asset.expectedSHA256)
            }
        }

        if let breathingURL = bundle.url(
            forResource: "dad_breathing",
            withExtension: "wav"
        ) {
            XCTAssertEqual(
                try sha256(breathingURL),
                "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"
            )
        }
    }

    private func audioControllerSource() throws -> String {
        let url = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/GravitasDemoAudioController.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func dadRuntimeSource() throws -> String {
        let url = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/" +
                "VocalBlendShape/DadVocalBlendShapeRuntime.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func immersiveCoordinatorSource() throws -> String {
        let url = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func dadWindowCoordinatorSource() throws -> String {
        let url = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/" +
                "Chapter01DadWindowCoordinator.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func functionBody(named name: String, in source: String) throws -> String {
        let signature = "func \(name)("
        let signatureRange = try XCTUnwrap(source.range(of: signature))
        let openingBrace = try XCTUnwrap(
            source[signatureRange.lowerBound...].firstIndex(of: "{")
        )
        var cursor = openingBrace
        var depth = 0
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(
            data: try Data(contentsOf: url, options: .mappedIfSafe)
        ).map { String(format: "%02x", $0) }.joined()
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
}
