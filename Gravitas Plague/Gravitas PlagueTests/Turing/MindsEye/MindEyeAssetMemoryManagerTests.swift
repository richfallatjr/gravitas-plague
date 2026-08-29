import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeAssetMemoryManagerTests: XCTestCase {
    func testSameVignettePrewarmsCoalesceAndIssueUniqueLeases() async throws {
        let loader = MindEyeTestPackageLoader(delayNanoseconds: 50_000_000)
        let manager = makeManager(loader: loader)

        async let firstResult = manager.prewarm(characterID: .bigMike, reason: "first")
        async let secondResult = manager.prewarm(characterID: .bigMike, reason: "second")
        async let thirdResult = manager.prewarm(characterID: .bigMike, reason: "third")
        let results = await (firstResult, secondResult, thirdResult)
        let leases = try [results.0, results.1, results.2].map(readyLease)

        XCTAssertEqual(Set(leases.map(\.id)).count, 3)
        let loadCount = await loader.invocationCount()
        XCTAssertEqual(loadCount, 1)
        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.state, .resident)
        XCTAssertEqual(snapshot.leaseCount, 3)
        XCTAssertEqual(snapshot.uniqueResidentPackageCount, 1)
        XCTAssertEqual(snapshot.uniqueInFlightPackageCount, 0)
    }

    func testActivationGatesPackageAccessAndFinalReleaseEvicts() async throws {
        let manager = makeManager(loader: MindEyeTestPackageLoader())
        let lease = try readyLease(
            await manager.prewarm(characterID: .bigMike, reason: "prewarm")
        )
        let beforeActivation = await manager.package(forActive: lease)
        XCTAssertNil(beforeActivation)
        let didActivate = await manager.activate(lease, reason: "present")
        XCTAssertTrue(didActivate)
        let activePackage = await manager.package(forActive: lease)
        XCTAssertEqual(activePackage?.vignetteID, "big_mike_current_room")

        await manager.deactivate(lease, reason: "hidden")
        let afterDeactivation = await manager.package(forActive: lease)
        XCTAssertNil(afterDeactivation)
        let inactive = await manager.snapshot()
        XCTAssertEqual(inactive.leaseCount, 1)
        XCTAssertEqual(inactive.activeLeaseCount, 0)

        await manager.release(lease, reason: "done")
        let released = await manager.snapshot()
        XCTAssertEqual(released.state, .empty)
        XCTAssertEqual(released.uniqueResidentPackageCount, 0)
        let staleActivation = await manager.activate(lease, reason: "stale")
        XCTAssertFalse(staleActivation)
    }

    func testActiveDifferentPackageReturnsConflictWithoutLoadingSecond() async throws {
        let loader = MindEyeTestPackageLoader()
        let manager = makeManager(loader: loader, includeRich: true)
        let mike = try readyLease(
            await manager.prewarm(characterID: .bigMike, reason: "mike")
        )
        let mikeActivated = await manager.activate(mike, reason: "active")
        XCTAssertTrue(mikeActivated)

        let rich = await manager.prewarm(characterID: .rich, reason: "overlap")
        guard case .unavailable(let failure) = rich else {
            return XCTFail("A different active package was replaced")
        }
        XCTAssertEqual(failure.code, .activePackageConflict)
        let loadCount = await loader.invocationCount()
        XCTAssertEqual(loadCount, 1)
        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.residentVignetteID, "big_mike_current_room")
        XCTAssertEqual(snapshot.activeLeaseCount, 1)
    }

    func testInactiveDifferentPackageEvictsBeforeLoadingReplacement() async throws {
        let loader = MindEyeTestPackageLoader()
        let manager = makeManager(loader: loader, includeRich: true)
        let mike = try readyLease(
            await manager.prewarm(characterID: .bigMike, reason: "mike")
        )
        let rich = try readyLease(
            await manager.prewarm(characterID: .rich, reason: "replace")
        )
        XCTAssertNotEqual(mike.generation, rich.generation)
        let staleMikeActivation = await manager.activate(mike, reason: "stale")
        let richActivation = await manager.activate(rich, reason: "rich")
        let loadCount = await loader.invocationCount()
        XCTAssertFalse(staleMikeActivation)
        XCTAssertTrue(richActivation)
        XCTAssertEqual(loadCount, 2)
        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.residentVignetteID, "rich_test_room")
        XCTAssertEqual(snapshot.uniqueResidentPackageCount, 1)
    }

    func testDifferentInFlightRequestRejectsStaleCompletion() async throws {
        let loader = MindEyeTestPackageLoader(delayNanoseconds: 100_000_000)
        let manager = makeManager(loader: loader, includeRich: true)
        let oldTask = Task {
            await manager.prewarm(characterID: .bigMike, reason: "old")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let richResult = await manager.prewarm(characterID: .rich, reason: "new")
        let oldResult = await oldTask.value
        let richLease = try readyLease(richResult)
        guard case .unavailable(let oldFailure) = oldResult else {
            return XCTFail("Stale request unexpectedly returned ready")
        }
        XCTAssertTrue([.staleLoad, .cancelled].contains(oldFailure.code))
        let richActivated = await manager.activate(richLease, reason: "new-active")
        XCTAssertTrue(richActivated)
        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.residentVignetteID, "rich_test_room")
        XCTAssertLessThanOrEqual(snapshot.uniqueResidentPackageCount, 1)
        XCTAssertLessThanOrEqual(snapshot.uniqueInFlightPackageCount, 1)
    }

    func testInactiveAndForcedEvictionAreIdempotent() async throws {
        let manager = makeManager(loader: MindEyeTestPackageLoader())
        let lease = try readyLease(
            await manager.prewarm(characterID: .bigMike, reason: "load")
        )
        let firstEviction = await manager.evictInactive(reason: "pressure")
        let secondEviction = await manager.evictInactive(reason: "pressure-again")
        let staleActivation = await manager.activate(lease, reason: "stale")
        XCTAssertTrue(firstEviction)
        XCTAssertFalse(secondEviction)
        XCTAssertFalse(staleActivation)

        let activeLease = try readyLease(
            await manager.prewarm(characterID: .bigMike, reason: "reload")
        )
        let active = await manager.activate(activeLease, reason: "active")
        let evictedActive = await manager.evictInactive(reason: "must-preserve")
        XCTAssertTrue(active)
        XCTAssertFalse(evictedActive)
        await manager.forceEvictAll(reason: "teardown")
        await manager.forceEvictAll(reason: "teardown-again")
        let invalidatedActivation = await manager.activate(activeLease, reason: "invalidated")
        let finalSnapshot = await manager.snapshot()
        XCTAssertFalse(invalidatedActivation)
        XCTAssertEqual(finalSnapshot.state, .empty)
    }

    func testMissingMappingAndLoaderFailureAreVisualOnly() async throws {
        let loader = MindEyeTestPackageLoader(failureCode: .textureLoadFailed)
        let manager = makeManager(loader: loader)
        let missing = await manager.prewarm(characterID: .rich, reason: "missing")
        let failed = await manager.prewarm(characterID: .bigMike, reason: "failure")
        guard case .unavailable(let missingFailure) = missing,
              case .unavailable(let loadFailure) = failed else {
            return XCTFail("Visual unavailability did not remain value-based")
        }
        XCTAssertEqual(missingFailure.code, .speakerNotMapped)
        XCTAssertEqual(loadFailure.code, .textureLoadFailed)
        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.state, .empty)
    }

    func testPackageOwnershipClearsAfterFinalRelease() async throws {
        let manager = makeManager(loader: MindEyeTestPackageLoader())
        let lease = try readyLease(
            await manager.prewarm(characterID: .bigMike, reason: "weak")
        )
        let didActivate = await manager.activate(lease, reason: "weak-active")
        XCTAssertTrue(didActivate)
        weak var weakPackage = await manager.package(forActive: lease)
        XCTAssertNotNil(weakPackage)
        await manager.release(lease, reason: "weak-release")
        for _ in 0 ..< 20 where weakPackage != nil {
            await Task.yield()
        }
        XCTAssertNil(weakPackage)
    }

    private func makeManager(
        loader: MindEyeTestPackageLoader,
        includeRich: Bool = false
    ) -> MindEyeAssetMemoryManager {
        var values: [TuringConversationCharacterID: MindEyeResolvedVignette] = [
            .bigMike: mindEyeMikeVignette()
        ]
        if includeRich {
            values[.rich] = MindEyeResolvedVignette(
                characterID: .rich,
                vignetteID: "rich_test_room",
                manifestResourcePath: "Turing/MindsEye/Vignettes/rich_test_room/manifest.json"
            )
        }
        return MindEyeAssetMemoryManager(
            catalog: MindEyeTestCatalog(values: values),
            loader: loader,
            memoryProbe: MindEyeTestMemoryProbe()
        )
    }

    private func readyLease(
        _ acquisition: MindEyeAssetAcquisition
    ) throws -> MindEyeAssetLease {
        guard case .ready(let lease) = acquisition else {
            throw MindEyeFailure(
                code: .packageConstructionFailed,
                characterID: nil,
                vignetteID: nil,
                resourcePath: nil,
                message: "Expected ready test acquisition, got \(acquisition)."
            )
        }
        return lease
    }
}

nonisolated struct MindEyeTestCatalog: MindEyeCatalogResolving {
    let values: [TuringConversationCharacterID: MindEyeResolvedVignette]

    func defaultVignette(
        for characterID: TuringConversationCharacterID
    ) async -> MindEyeResolvedVignette? {
        values[characterID]
    }
}

actor MindEyeTestPackageLoader: MindEyeAssetPackageLoading {
    private let delayNanoseconds: UInt64
    private let failureCode: MindEyeFailureCode?
    private var calls = 0

    init(
        delayNanoseconds: UInt64 = 0,
        failureCode: MindEyeFailureCode? = nil
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.failureCode = failureCode
    }

    func loadPackage(
        _ vignette: MindEyeResolvedVignette
    ) async -> Result<MindEyeAssetPackage, MindEyeFailure> {
        calls += 1
        do {
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            try Task.checkCancellation()
            if let failureCode {
                return .failure(
                    MindEyeFailure(
                        code: failureCode,
                        characterID: vignette.characterID,
                        vignetteID: vignette.vignetteID,
                        resourcePath: nil,
                        message: "Injected loader failure."
                    )
                )
            }
            return .success(
                try makeMindEyeTestPackage(
                    characterID: vignette.characterID,
                    vignetteID: vignette.vignetteID
                )
            )
        } catch is CancellationError {
            return .failure(
                MindEyeFailure(
                    code: .cancelled,
                    characterID: vignette.characterID,
                    vignetteID: vignette.vignetteID,
                    resourcePath: nil,
                    message: "Injected loader cancelled."
                )
            )
        } catch {
            return .failure(
                MindEyeFailure(
                    code: .packageConstructionFailed,
                    characterID: vignette.characterID,
                    vignetteID: vignette.vignetteID,
                    resourcePath: nil,
                    message: error.localizedDescription
                )
            )
        }
    }

    func invocationCount() -> Int { calls }
}
