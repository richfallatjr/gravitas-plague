import Foundation

nonisolated struct MindEyeAuthoredFrameTrackLease:
    Sendable,
    Equatable,
    Hashable
{
    let id: UUID
    let prID: String
    let generation: UInt64
}

nonisolated enum MindEyeAuthoredFrameTrackAcquisition: Sendable {
    case ready(
        lease: MindEyeAuthoredFrameTrackLease,
        track: MindEyeAuthoredFrameTrack
    )
    case unavailable(MindEyeFailure)
}

nonisolated protocol MindEyeAuthoredFrameTrackManaging: Sendable {
    func prepareIndex() async -> Result<MindEyeAuthoredFrameIndexSnapshot, MindEyeFailure>
    func prewarm(
        prID: String,
        expectedSpeaker: TuringConversationCharacterID,
        expectedSurface: StoryInteractionSurfaceID,
        reason: String
    ) async -> Result<Void, MindEyeFailure>
    func acquire(
        prID: String,
        expectedSpeaker: TuringConversationCharacterID,
        expectedSurface: StoryInteractionSurfaceID,
        reason: String
    ) async -> MindEyeAuthoredFrameTrackAcquisition
    func release(_ lease: MindEyeAuthoredFrameTrackLease, reason: String) async
    func evictInactive(reason: String) async
    func forceEvictAll(reason: String) async
    func snapshot() async -> MindEyeAuthoredFrameStoreSnapshot
}

nonisolated struct MindEyeAuthoredFrameStoreSnapshot:
    Sendable,
    Equatable
{
    let indexReady: Bool
    let cachedPRIDs: [String]
    let leasedPRIDs: [String]
    let loadingPRIDs: [String]
    let maximumResidentTracks: Int
    let estimatedCompactBytes: Int
}

actor MindEyeAuthoredFrameTrackStore: MindEyeAuthoredFrameTrackManaging {
    static let shared = MindEyeAuthoredFrameTrackStore.makeDefault()

    private struct CacheEntry {
        let generation: UInt64
        let track: MindEyeAuthoredFrameTrack
        var leaseIDs: Set<UUID>
        var lastAccessOrdinal: UInt64
    }

    private let locator: MindEyeResourceLocator
    private let worker: any MindEyeAuthoredFrameWorking
    private let maximumResidentTracks: Int
    private var indexResult: Result<MindEyeAuthoredFrameIndexSnapshot, MindEyeFailure>?
    private var indexTask: Task<Result<MindEyeAuthoredFrameIndexSnapshot, MindEyeFailure>, Never>?
    private var loadTasks: [String: Task<Result<MindEyeAuthoredFrameTrack, MindEyeFailure>, Never>] = [:]
    private var cache: [String: CacheEntry] = [:]
    private var generation: UInt64 = 0
    private var accessOrdinal: UInt64 = 0

    init(
        locator: MindEyeResourceLocator,
        worker: any MindEyeAuthoredFrameWorking,
        maximumResidentTracks: Int = 2
    ) {
        self.locator = locator
        self.worker = worker
        self.maximumResidentTracks = max(1, maximumResidentTracks)
    }

    static func makeDefault() -> MindEyeAuthoredFrameTrackStore {
        do {
            return MindEyeAuthoredFrameTrackStore(
                locator: try .applicationBundle(),
                worker: MindEyeSerialAuthoredFrameWorker(),
                maximumResidentTracks: 2
            )
        } catch {
            return MindEyeAuthoredFrameTrackStore(
                locator: MindEyeResourceLocator(
                    resourceRootURL: URL(fileURLWithPath: "/nonexistent", isDirectory: true)
                ),
                worker: MindEyeUnavailableAuthoredFrameWorker(error: error),
                maximumResidentTracks: 2
            )
        }
    }

    func prepareIndex() async -> Result<MindEyeAuthoredFrameIndexSnapshot, MindEyeFailure> {
        if let indexResult { return indexResult }
        if let indexTask { return await indexTask.value }
        let locator = locator
        let worker = worker
        let task = Task<Result<MindEyeAuthoredFrameIndexSnapshot, MindEyeFailure>, Never> {
            do {
                return .success(try await worker.loadIndex(locator: locator))
            } catch {
                return .failure(Self.failure(
                    error,
                    code: .authoredFrameIndexInvalid,
                    resourcePath: "Turing/MindsEye/AudioFrames/index.json"
                ))
            }
        }
        indexTask = task
        let result = await task.value
        indexTask = nil
        indexResult = result
        return result
    }

    func prewarm(
        prID: String,
        expectedSpeaker: TuringConversationCharacterID,
        expectedSurface: StoryInteractionSurfaceID,
        reason: String
    ) async -> Result<Void, MindEyeFailure> {
        switch await validatedEntry(
            prID: prID,
            expectedSpeaker: expectedSpeaker,
            expectedSurface: expectedSurface
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let entry):
            if touchCached(prID: prID) {
                print("[MindEyeAuthored] prewarm hit prID=\(prID) reason=\(reason)")
                return .success(())
            }
            guard hasCapacityForNewTrack else {
                return .failure(cacheConflict(prID: prID))
            }
            switch await load(entry: entry) {
            case .failure(let failure): return .failure(failure)
            case .success(let track):
                insertIfNeeded(track)
                evictInactiveNow(reason: "prewarm.\(reason)")
                print("[MindEyeAuthored] prewarm miss loaded prID=\(prID) reason=\(reason)")
                return .success(())
            }
        }
    }

    func acquire(
        prID: String,
        expectedSpeaker: TuringConversationCharacterID,
        expectedSurface: StoryInteractionSurfaceID,
        reason: String
    ) async -> MindEyeAuthoredFrameTrackAcquisition {
        let entry: MindEyeAuthoredFrameIndex.Entry
        switch await validatedEntry(
            prID: prID,
            expectedSpeaker: expectedSpeaker,
            expectedSurface: expectedSurface
        ) {
        case .failure(let failure): return .unavailable(failure)
        case .success(let value): entry = value
        }

        if cache[prID] == nil {
            guard hasCapacityForNewTrack else {
                return .unavailable(cacheConflict(prID: prID))
            }
            switch await load(entry: entry) {
            case .failure(let failure): return .unavailable(failure)
            case .success(let track):
                insertIfNeeded(track)
                evictInactiveNow(reason: "acquire.\(reason)")
            }
        }

        guard var cached = cache[prID] else {
            return .unavailable(MindEyeFailure(
                code: .authoredFrameTrackUnavailable,
                characterID: expectedSpeaker,
                vignetteID: nil,
                resourcePath: entry.manifestResourcePath,
                message: "Compact authored frame track was not cached after loading."
            ))
        }
        accessOrdinal &+= 1
        cached.lastAccessOrdinal = accessOrdinal
        let lease = MindEyeAuthoredFrameTrackLease(
            id: UUID(),
            prID: prID,
            generation: cached.generation
        )
        cached.leaseIDs.insert(lease.id)
        cache[prID] = cached
        print("[MindEyeAuthored] acquired prID=\(prID) reason=\(reason)")
        return .ready(lease: lease, track: cached.track)
    }

    func release(_ lease: MindEyeAuthoredFrameTrackLease, reason: String) async {
        guard var entry = cache[lease.prID],
              entry.generation == lease.generation,
              entry.leaseIDs.remove(lease.id) != nil else {
            print("[MindEyeAuthored] stale release ignored prID=\(lease.prID) reason=\(reason)")
            return
        }
        accessOrdinal &+= 1
        entry.lastAccessOrdinal = accessOrdinal
        cache[lease.prID] = entry
        evictInactiveNow(reason: reason)
        print("[MindEyeAuthored] released prID=\(lease.prID) reason=\(reason)")
    }

    func evictInactive(reason: String) async {
        let inactive = cache
            .filter { $0.value.leaseIDs.isEmpty }
            .sorted {
                if $0.value.lastAccessOrdinal == $1.value.lastAccessOrdinal {
                    return $0.key < $1.key
                }
                return $0.value.lastAccessOrdinal < $1.value.lastAccessOrdinal
            }
        for (prID, _) in inactive {
            cache.removeValue(forKey: prID)
            print("[MindEyeAuthored] evicted prID=\(prID) reason=\(reason)")
        }
    }

    func forceEvictAll(reason: String) async {
        generation &+= 1
        indexTask?.cancel()
        indexTask = nil
        for task in loadTasks.values { task.cancel() }
        loadTasks.removeAll(keepingCapacity: false)
        let leased = cache.values.reduce(0) { $0 + $1.leaseIDs.count }
        cache.removeAll(keepingCapacity: false)
        print(
            "[MindEyeAuthored] force evicted all reason=\(reason) " +
                "staleLeasesInvalidated=\(leased)"
        )
    }

    func snapshot() -> MindEyeAuthoredFrameStoreSnapshot {
        MindEyeAuthoredFrameStoreSnapshot(
            indexReady: indexResult?.successValue != nil,
            cachedPRIDs: cache.keys.sorted(),
            leasedPRIDs: cache.compactMap {
                $0.value.leaseIDs.isEmpty ? nil : $0.key
            }.sorted(),
            loadingPRIDs: loadTasks.keys.sorted(),
            maximumResidentTracks: maximumResidentTracks,
            estimatedCompactBytes: cache.values.reduce(0) {
                $0 + $1.track.estimatedCompactByteCount
            }
        )
    }

    private func validatedEntry(
        prID: String,
        expectedSpeaker: TuringConversationCharacterID,
        expectedSurface: StoryInteractionSurfaceID
    ) async -> Result<MindEyeAuthoredFrameIndex.Entry, MindEyeFailure> {
        let snapshot: MindEyeAuthoredFrameIndexSnapshot
        switch await prepareIndex() {
        case .failure(let failure): return .failure(failure)
        case .success(let value): snapshot = value
        }
        guard let entry = snapshot.entry(for: prID) else {
            return .failure(MindEyeFailure(
                code: .authoredFrameTrackUnavailable,
                characterID: expectedSpeaker,
                vignetteID: nil,
                resourcePath: nil,
                message: "No authored frame track is published for \(prID)."
            ))
        }
        guard entry.speakerCharacterID == expectedSpeaker else {
            return .failure(MindEyeFailure(
                code: .authoredFrameSpeakerMismatch,
                characterID: expectedSpeaker,
                vignetteID: nil,
                resourcePath: entry.manifestResourcePath,
                message: "Published authored frame speaker does not match actual audio."
            ))
        }
        guard entry.interactionSurface == expectedSurface else {
            return .failure(MindEyeFailure(
                code: .authoredFrameSurfaceMismatch,
                characterID: expectedSpeaker,
                vignetteID: nil,
                resourcePath: entry.manifestResourcePath,
                message: "Published authored frame surface does not match actual audio."
            ))
        }
        return .success(entry)
    }

    private func load(
        entry: MindEyeAuthoredFrameIndex.Entry
    ) async -> Result<MindEyeAuthoredFrameTrack, MindEyeFailure> {
        if let cached = cache[entry.prID] { return .success(cached.track) }
        if let task = loadTasks[entry.prID] { return await task.value }
        let locator = locator
        let worker = worker
        let task = Task<Result<MindEyeAuthoredFrameTrack, MindEyeFailure>, Never> {
            do {
                let track = try await worker.loadTrack(indexEntry: entry, locator: locator)
                guard track.descriptor.prID == entry.prID,
                      track.descriptor.speakerCharacterID == entry.speakerCharacterID,
                      track.descriptor.interactionSurface == entry.interactionSurface else {
                    throw MindEyeFailure(
                        code: .authoredFrameTrackInvalid,
                        characterID: entry.speakerCharacterID,
                        vignetteID: nil,
                        resourcePath: entry.manifestResourcePath,
                        message: "Worker returned a mismatched compact authored frame track."
                    )
                }
                return .success(track)
            } catch {
                return .failure(Self.failure(
                    error,
                    code: .authoredFrameTrackUnavailable,
                    characterID: entry.speakerCharacterID,
                    resourcePath: entry.manifestResourcePath
                ))
            }
        }
        loadTasks[entry.prID] = task
        let result = await task.value
        loadTasks.removeValue(forKey: entry.prID)
        return result
    }

    private func insertIfNeeded(_ track: MindEyeAuthoredFrameTrack) {
        guard cache[track.descriptor.prID] == nil else { return }
        generation &+= 1
        accessOrdinal &+= 1
        cache[track.descriptor.prID] = CacheEntry(
            generation: generation,
            track: track,
            leaseIDs: [],
            lastAccessOrdinal: accessOrdinal
        )
    }

    @discardableResult
    private func touchCached(prID: String) -> Bool {
        guard var entry = cache[prID] else { return false }
        accessOrdinal &+= 1
        entry.lastAccessOrdinal = accessOrdinal
        cache[prID] = entry
        return true
    }

    private var hasCapacityForNewTrack: Bool {
        cache.count < maximumResidentTracks || cache.values.contains { $0.leaseIDs.isEmpty }
    }

    private func evictInactiveNow(reason: String) {
        while cache.count > maximumResidentTracks {
            guard let candidate = cache
                .filter({ $0.value.leaseIDs.isEmpty })
                .min(by: {
                    if $0.value.lastAccessOrdinal == $1.value.lastAccessOrdinal {
                        return $0.key < $1.key
                    }
                    return $0.value.lastAccessOrdinal < $1.value.lastAccessOrdinal
                }) else { return }
            cache.removeValue(forKey: candidate.key)
            print("[MindEyeAuthored] evicted prID=\(candidate.key) reason=\(reason)")
        }
    }

    private func cacheConflict(prID: String) -> MindEyeFailure {
        MindEyeFailure(
            code: .authoredFrameTrackCacheConflict,
            characterID: nil,
            vignetteID: nil,
            resourcePath: nil,
            message: "Two compact authored tracks are pinned; \(prID) remains rest-mouth."
        )
    }

    private static func failure(
        _ error: Error,
        code: MindEyeFailureCode,
        characterID: TuringConversationCharacterID? = nil,
        resourcePath: String?
    ) -> MindEyeFailure {
        if let failure = error as? MindEyeFailure { return failure }
        return MindEyeFailure(
            code: code,
            characterID: characterID,
            vignetteID: nil,
            resourcePath: resourcePath,
            message: error.localizedDescription
        )
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
