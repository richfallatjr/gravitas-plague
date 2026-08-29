import Foundation
import Metal

nonisolated struct MindEyeAssetLease:
    Sendable,
    Equatable,
    Hashable
{
    let id: UUID
    let generation: UInt64
    let characterID: TuringConversationCharacterID
    let vignetteID: String
}

nonisolated struct MindEyeAssetMemorySnapshot:
    Sendable,
    Equatable
{
    enum State: String, Sendable, Equatable {
        case empty
        case loading
        case resident
    }

    let state: State
    let generation: UInt64
    let loadingVignetteID: String?
    let residentVignetteID: String?
    let leaseCount: Int
    let activeLeaseCount: Int
    let uniqueResidentPackageCount: Int
    let uniqueInFlightPackageCount: Int
    let residentSourceTextureCount: Int
    let residentSourceTextureAllocatedBytes: UInt64
}

nonisolated protocol MindEyeInactiveAssetEvicting: Sendable {
    @discardableResult
    func evictInactive(reason: String) async -> Bool
}

nonisolated protocol MindEyeAssetMemoryManaging:
    Sendable,
    MindEyeInactiveAssetEvicting
{
    func prewarm(
        characterID: TuringConversationCharacterID,
        reason: String
    ) async -> MindEyeAssetAcquisition

    func activate(_ lease: MindEyeAssetLease, reason: String) async -> Bool
    func package(forActive lease: MindEyeAssetLease) async -> MindEyeAssetPackage?
    func deactivate(_ lease: MindEyeAssetLease, reason: String) async
    func release(_ lease: MindEyeAssetLease, reason: String) async
    func forceEvictAll(reason: String) async
    func snapshot() async -> MindEyeAssetMemorySnapshot
}

actor MindEyeAssetMemoryManager: MindEyeAssetMemoryManaging {
    static let shared = MindEyeAssetMemoryManager.makeDefault()

    private struct Loading {
        let generation: UInt64
        let requestID: UUID
        let characterID: TuringConversationCharacterID
        let vignette: MindEyeResolvedVignette
        let task: Task<Result<MindEyeAssetPackage, MindEyeFailure>, Never>
    }

    private struct Resident {
        let generation: UInt64
        let package: MindEyeAssetPackage
        var leaseIDs: Set<UUID>
        var activeLeaseIDs: Set<UUID>
    }

    private struct ReleasedPackageInfo: Sendable {
        let characterID: TuringConversationCharacterID
        let vignetteID: String
        let estimatedResidentSourceBytes: UInt64
    }

    private let catalog: any MindEyeCatalogResolving
    private let loader: any MindEyeAssetPackageLoading
    private let memoryProbe: any MindEyeMemoryProbing

    private var generation: UInt64 = 0
    private var loading: Loading?
    private var resident: Resident?

    init(
        catalog: any MindEyeCatalogResolving,
        loader: any MindEyeAssetPackageLoading,
        memoryProbe: any MindEyeMemoryProbing = MindEyeNoopMemoryProbe()
    ) {
        self.catalog = catalog
        self.loader = loader
        self.memoryProbe = memoryProbe
    }

    nonisolated static func makeDefault() -> MindEyeAssetMemoryManager {
        let probe = TuringMindEyeMemoryProbe()
        let worker = MindEyeSerialAssetWorker()
        do {
            let locator = try MindEyeResourceLocator.applicationBundle()
            let catalog = MindEyeCatalogStore(locator: locator, worker: worker)
            guard let device = MTLCreateSystemDefaultDevice() else {
                return MindEyeAssetMemoryManager(
                    catalog: catalog,
                    loader: MindEyeUnavailablePackageLoader(code: .noMetalDevice),
                    memoryProbe: probe
                )
            }
            let textureLoader = MindEyeSerialTextureLoader(device: device)
            let packageLoader = MindEyeAssetPackageLoader(
                locator: locator,
                worker: worker,
                textureLoader: textureLoader,
                memoryProbe: probe
            )
            return MindEyeAssetMemoryManager(
                catalog: catalog,
                loader: packageLoader,
                memoryProbe: probe
            )
        } catch {
            return MindEyeAssetMemoryManager(
                catalog: MindEyeUnavailableCatalog(),
                loader: MindEyeUnavailablePackageLoader(code: .catalogMissing),
                memoryProbe: probe
            )
        }
    }

    func prewarm(
        characterID: TuringConversationCharacterID,
        reason: String
    ) async -> MindEyeAssetAcquisition {
        guard let vignette = await catalog.defaultVignette(for: characterID) else {
            return await unavailable(
                MindEyeFailure(
                    code: .speakerNotMapped,
                    characterID: characterID,
                    vignetteID: nil,
                    resourcePath: nil,
                    message: "No Mind's Eye vignette is mapped for the audible speaker."
                ),
                reason: reason
            )
        }
        return await prewarmResolved(vignette, reason: reason)
    }

    private func prewarmResolved(
        _ vignette: MindEyeResolvedVignette,
        reason: String
    ) async -> MindEyeAssetAcquisition {
        if let resident,
           resident.package.characterID == vignette.characterID,
           resident.package.vignetteID == vignette.vignetteID {
            let lease = issueLease(for: resident)
            assertInvariants()
            return .ready(lease)
        }

        if let resident, !resident.activeLeaseIDs.isEmpty {
            return await unavailable(
                MindEyeFailure(
                    code: .activePackageConflict,
                    characterID: vignette.characterID,
                    vignetteID: vignette.vignetteID,
                    resourcePath: nil,
                    message: "A different active Mind's Eye package owns the one-package budget."
                ),
                reason: reason
            )
        }

        if resident != nil {
            await releaseResident(reason: "replaceInactive.\(reason)")
            return await prewarmResolved(vignette, reason: reason)
        }

        if let loading {
            if loading.characterID == vignette.characterID,
               loading.vignette.vignetteID == vignette.vignetteID {
                let expectedGeneration = loading.generation
                let expectedRequestID = loading.requestID
                let result = await loading.task.value
                return await finishLoad(
                    result,
                    vignette: vignette,
                    generation: expectedGeneration,
                    requestID: expectedRequestID,
                    reason: reason
                )
            }
            loading.task.cancel()
            self.loading = nil
            incrementGeneration()
            assertInvariants()
            await memoryProbe.record(
                label: "mindseye.manager.load.cancelled",
                characterID: loading.characterID,
                vignetteID: loading.vignette.vignetteID,
                details: ["reason": "replaced.\(reason)"]
            )
            return await prewarmResolved(vignette, reason: reason)
        }

        incrementGeneration()
        let loadGeneration = generation
        let requestID = UUID()
        let loader = loader
        let task = Task<Result<MindEyeAssetPackage, MindEyeFailure>, Never> {
            await loader.loadPackage(vignette)
        }
        loading = Loading(
            generation: loadGeneration,
            requestID: requestID,
            characterID: vignette.characterID,
            vignette: vignette,
            task: task
        )
        assertInvariants()
        let result = await task.value
        return await finishLoad(
            result,
            vignette: vignette,
            generation: loadGeneration,
            requestID: requestID,
            reason: reason
        )
    }

    private func finishLoad(
        _ result: Result<MindEyeAssetPackage, MindEyeFailure>,
        vignette: MindEyeResolvedVignette,
        generation expectedGeneration: UInt64,
        requestID expectedRequestID: UUID,
        reason: String
    ) async -> MindEyeAssetAcquisition {
        if let resident,
           resident.generation == expectedGeneration,
           resident.package.characterID == vignette.characterID,
           resident.package.vignetteID == vignette.vignetteID {
            let lease = issueLease(for: resident)
            assertInvariants()
            return .ready(lease)
        }

        guard let loading,
              loading.generation == expectedGeneration,
              loading.requestID == expectedRequestID,
              loading.characterID == vignette.characterID,
              loading.vignette.vignetteID == vignette.vignetteID,
              generation == expectedGeneration else {
            return await unavailable(
                MindEyeFailure(
                    code: .staleLoad,
                    characterID: vignette.characterID,
                    vignetteID: vignette.vignetteID,
                    resourcePath: nil,
                    message: "A stale Mind's Eye package load was rejected."
                ),
                reason: reason
            )
        }
        self.loading = nil

        switch result {
        case .failure(let failure):
            assertInvariants()
            return await unavailable(failure, reason: reason)
        case .success(let package):
            guard package.characterID == vignette.characterID,
                  package.vignetteID == vignette.vignetteID,
                  resident == nil else {
                assertInvariants()
                return await unavailable(
                    MindEyeFailure(
                        code: .staleLoad,
                        characterID: vignette.characterID,
                        vignetteID: vignette.vignetteID,
                        resourcePath: nil,
                        message: "Loaded package identity no longer matches manager state."
                    ),
                    reason: reason
                )
            }
            let leaseID = UUID()
            resident = Resident(
                generation: expectedGeneration,
                package: package,
                leaseIDs: [leaseID],
                activeLeaseIDs: []
            )
            assertInvariants()
            await memoryProbe.record(
                label: "mindseye.manager.resident.installed",
                characterID: package.characterID,
                vignetteID: package.vignetteID,
                details: [
                    "reason": reason,
                    "leaseCount": "1",
                    "sourceTextureCount": String(package.allSourceTextures.count),
                    "estimatedResidentSourceBytes": String(package.estimatedResidentSourceBytes)
                ]
            )
            guard let current = resident,
                  current.generation == expectedGeneration,
                  current.leaseIDs.contains(leaseID) else {
                return await unavailable(
                    MindEyeFailure(
                        code: .staleLoad,
                        characterID: vignette.characterID,
                        vignetteID: vignette.vignetteID,
                        resourcePath: nil,
                        message: "Installed package was evicted before its lease could return."
                    ),
                    reason: reason
                )
            }
            return .ready(
                MindEyeAssetLease(
                    id: leaseID,
                    generation: expectedGeneration,
                    characterID: package.characterID,
                    vignetteID: package.vignetteID
                )
            )
        }
    }

    func activate(_ lease: MindEyeAssetLease, reason: String) async -> Bool {
        guard var resident,
              validates(lease, resident: resident) else {
            return false
        }
        resident.activeLeaseIDs.insert(lease.id)
        self.resident = resident
        assertInvariants()
        return true
    }

    func package(
        forActive lease: MindEyeAssetLease
    ) async -> MindEyeAssetPackage? {
        guard let resident,
              validates(lease, resident: resident),
              resident.activeLeaseIDs.contains(lease.id) else {
            return nil
        }
        return resident.package
    }

    func deactivate(_ lease: MindEyeAssetLease, reason: String) async {
        guard var resident, validates(lease, resident: resident) else {
            return
        }
        resident.activeLeaseIDs.remove(lease.id)
        self.resident = resident
        assertInvariants()
    }

    func release(_ lease: MindEyeAssetLease, reason: String) async {
        var shouldReleaseResident = false
        do {
            guard var current = resident,
                  validates(lease, resident: current) else {
                return
            }
            current.activeLeaseIDs.remove(lease.id)
            current.leaseIDs.remove(lease.id)
            shouldReleaseResident = current.leaseIDs.isEmpty
            resident = current
        }
        if shouldReleaseResident {
            await releaseResident(reason: reason)
        } else {
            assertInvariants()
        }
    }

    @discardableResult
    func evictInactive(reason: String) async -> Bool {
        let cancelledLoad = loading
        if cancelledLoad != nil {
            cancelledLoad?.task.cancel()
            loading = nil
            incrementGeneration()
        }
        if let resident, !resident.activeLeaseIDs.isEmpty {
            assertInvariants()
            if let cancelledLoad {
                await logCancelledLoad(cancelledLoad, reason: reason)
            }
            return false
        }
        let releasedPackage = detachResident(increment: cancelledLoad == nil)
        assertInvariants()
        if let cancelledLoad {
            await logCancelledLoad(cancelledLoad, reason: reason)
        }
        if let releasedPackage {
            await logReleasedPackage(releasedPackage, reason: reason)
        }
        return cancelledLoad != nil || releasedPackage != nil
    }

    func forceEvictAll(reason: String) async {
        let cancelledLoad = loading
        cancelledLoad?.task.cancel()
        loading = nil
        let releasedPackage = detachResident(increment: false)
        guard cancelledLoad != nil || releasedPackage != nil else {
            assertInvariants()
            return
        }
        incrementGeneration()
        assertInvariants()
        if let cancelledLoad {
            await logCancelledLoad(cancelledLoad, reason: reason)
        }
        if let releasedPackage {
            await logReleasedPackage(releasedPackage, reason: reason)
        }
    }

    private func logCancelledLoad(
        _ cancelledLoad: Loading,
        reason: String
    ) async {
            await memoryProbe.record(
                label: "mindseye.manager.load.cancelled",
                characterID: cancelledLoad.characterID,
                vignetteID: cancelledLoad.vignette.vignetteID,
                details: ["reason": reason]
            )
    }

    func snapshot() async -> MindEyeAssetMemorySnapshot {
        assertInvariants()
        let state: MindEyeAssetMemorySnapshot.State
        if resident != nil {
            state = .resident
        } else if loading != nil {
            state = .loading
        } else {
            state = .empty
        }
        return MindEyeAssetMemorySnapshot(
            state: state,
            generation: generation,
            loadingVignetteID: loading?.vignette.vignetteID,
            residentVignetteID: resident?.package.vignetteID,
            leaseCount: resident?.leaseIDs.count ?? 0,
            activeLeaseCount: resident?.activeLeaseIDs.count ?? 0,
            uniqueResidentPackageCount: resident == nil ? 0 : 1,
            uniqueInFlightPackageCount: loading == nil ? 0 : 1,
            residentSourceTextureCount: resident?.package.allSourceTextures.count ?? 0,
            residentSourceTextureAllocatedBytes: resident?.package.allSourceTextures.reduce(0) {
                $0 + UInt64($1.texture.allocatedSize)
            } ?? 0
        )
    }

    private func issueLease(for resident: Resident) -> MindEyeAssetLease {
        let leaseID = UUID()
        var updated = resident
        updated.leaseIDs.insert(leaseID)
        self.resident = updated
        return MindEyeAssetLease(
            id: leaseID,
            generation: resident.generation,
            characterID: resident.package.characterID,
            vignetteID: resident.package.vignetteID
        )
    }

    private func validates(
        _ lease: MindEyeAssetLease,
        resident: Resident
    ) -> Bool {
        lease.generation == resident.generation &&
            lease.characterID == resident.package.characterID &&
            lease.vignetteID == resident.package.vignetteID &&
            resident.leaseIDs.contains(lease.id)
    }

    private func releaseResident(
        reason: String,
        increment: Bool = true
    ) async {
        guard let info = detachResident(increment: increment) else { return }
        assertInvariants()
        await logReleasedPackage(info, reason: reason)
    }

    private func detachResident(
        increment: Bool
    ) -> ReleasedPackageInfo? {
        guard let current = resident else { return nil }
        let info = ReleasedPackageInfo(
            characterID: current.package.characterID,
            vignetteID: current.package.vignetteID,
            estimatedResidentSourceBytes: current.package.estimatedResidentSourceBytes
        )
        resident = nil
        if increment {
            incrementGeneration()
        }
        return info
    }

    private func logReleasedPackage(
        _ info: ReleasedPackageInfo,
        reason: String
    ) async {
        await memoryProbe.record(
            label: "mindseye.manager.resident.release.begin",
            characterID: info.characterID,
            vignetteID: info.vignetteID,
            details: [
                "reason": reason,
                "estimatedResidentSourceBytes": String(
                    info.estimatedResidentSourceBytes
                )
            ]
        )
        await memoryProbe.record(
            label: "mindseye.manager.resident.release.end",
            characterID: info.characterID,
            vignetteID: info.vignetteID,
            details: ["reason": reason]
        )
    }

    private func unavailable(
        _ failure: MindEyeFailure,
        reason: String
    ) async -> MindEyeAssetAcquisition {
        print(
            "[MindEye] visual unavailable code=\(failure.code.rawValue) " +
            "character=\(failure.characterID?.rawValue ?? "none") " +
            "vignette=\(failure.vignetteID ?? "none") reason=\(reason)"
        )
        await memoryProbe.record(
            label: "mindseye.manager.acquire.unavailable",
            characterID: failure.characterID,
            vignetteID: failure.vignetteID,
            details: [
                "reason": reason,
                "failureCode": failure.code.rawValue
            ]
        )
        return .unavailable(failure)
    }

    private func incrementGeneration() {
        generation &+= 1
    }

    private func assertInvariants() {
        assert(resident == nil || loading == nil)
        if let resident {
            assert(resident.activeLeaseIDs.isSubset(of: resident.leaseIDs))
            assert(resident.generation <= generation)
        }
        if let loading {
            assert(loading.generation <= generation)
        }
    }
}

nonisolated struct MindEyeUnavailableCatalog: MindEyeCatalogResolving {
    func defaultVignette(
        for characterID: TuringConversationCharacterID
    ) async -> MindEyeResolvedVignette? {
        nil
    }
}

nonisolated struct MindEyeUnavailablePackageLoader: MindEyeAssetPackageLoading {
    let code: MindEyeFailureCode

    func loadPackage(
        _ vignette: MindEyeResolvedVignette
    ) async -> Result<MindEyeAssetPackage, MindEyeFailure> {
        .failure(
            MindEyeFailure(
                code: code,
                characterID: vignette.characterID,
                vignetteID: vignette.vignetteID,
                resourcePath: nil,
                message: "Mind's Eye package loading is unavailable."
            )
        )
    }
}
