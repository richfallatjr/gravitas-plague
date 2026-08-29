import Foundation

nonisolated struct MindEyeFillerFrameTrackLease: Sendable, Equatable, Hashable {
    let id: UUID
    let fillerID: String
    let cacheKey: String
    let generation: UInt64
}

nonisolated enum MindEyeFillerFrameTrackAcquisition: Sendable {
    case ready(MindEyeFillerFrameTrackLease, MindEyeAuthoredFrameTrack)
    case unavailable(MindEyeFailure)
}

nonisolated struct MindEyeFillerFrameTrackStoreSnapshot: Sendable, Equatable {
    let cachedFillerIDs: [String]
    let leasedFillerIDs: [String]
    let loadingFillerIDs: [String]
    let compactByteCount: Int
}

actor MindEyeFillerFrameTrackStore {
    static let shared = MindEyeFillerFrameTrackStore.makeDefault()

    private struct Cached {
        let generation: UInt64
        let track: MindEyeAuthoredFrameTrack
        var leases: Set<UUID>
        var ordinal: UInt64
    }

    private struct InFlight {
        let id: UUID
        let generation: UInt64
        let task: Task<Result<MindEyeAuthoredFrameTrack, MindEyeFailure>, Never>
    }

    private let locator: MindEyeResourceLocator
    private let worker: any MindEyeFillerFrameWorking
    private var index: Result<MindEyeFillerFrameIndexSnapshot, MindEyeFailure>?
    private var indexTask: Task<Result<MindEyeFillerFrameIndexSnapshot, MindEyeFailure>, Never>?
    private var cache: [String: Cached] = [:]
    private var inFlight: [String: InFlight] = [:]
    private var generation: UInt64 = 0
    private var loadEpoch: UInt64 = 0
    private var ordinal: UInt64 = 0
    private let maximumTracks = 8
    private let maximumBytes = 512 * 1024

    init(locator: MindEyeResourceLocator, worker: any MindEyeFillerFrameWorking) {
        self.locator = locator
        self.worker = worker
    }

    static func makeDefault() -> MindEyeFillerFrameTrackStore {
        let locator = (try? MindEyeResourceLocator.applicationBundle()) ??
            MindEyeResourceLocator(resourceRootURL: URL(fileURLWithPath: "/nonexistent"))
        return MindEyeFillerFrameTrackStore(
            locator: locator,
            worker: MindEyeSerialFillerFrameWorker()
        )
    }

    func prepareIndex() async -> Result<MindEyeFillerFrameIndexSnapshot, MindEyeFailure> {
        if let index { return index }
        let epoch = loadEpoch
        if let indexTask {
            let result = await indexTask.value
            guard epoch == loadEpoch else { return .failure(Self.staleIndexFailure()) }
            if index == nil { index = result }
            return index ?? result
        }
        let worker = worker
        let locator = locator
        let task = Task<Result<MindEyeFillerFrameIndexSnapshot, MindEyeFailure>, Never> {
            do {
                return .success(try await worker.loadIndex(locator: locator))
            } catch let failure as MindEyeFailure {
                return .failure(failure)
            } catch {
                return .failure(MindEyeFailure(
                    code: .authoredFrameIndexInvalid,
                    characterID: nil,
                    vignetteID: nil,
                    resourcePath: "Turing/MindsEye/Fillers/index.json",
                    message: error.localizedDescription
                ))
            }
        }
        indexTask = task
        let result = await task.value
        guard epoch == loadEpoch else { return .failure(Self.staleIndexFailure()) }
        if index == nil { index = result }
        indexTask = nil
        return index ?? result
    }

    func acquire(
        clip: TuringFillerClipDescriptor,
        expectedSurface: StoryInteractionSurfaceID,
        reason: String
    ) async -> MindEyeFillerFrameTrackAcquisition {
        let cacheKey = "\(clip.identity.fillerID)|\(expectedSurface.rawValue)"
        switch await loadAndCache(
            clip: clip,
            expectedSurface: expectedSurface,
            cacheKey: cacheKey
        ) {
        case .failure(let failure): return .unavailable(failure)
        case .success: break
        }
        guard var cached = cache[cacheKey] else {
            return .unavailable(Self.failure(clip, "Filler track cache rejected the track."))
        }
        let lease = MindEyeFillerFrameTrackLease(
            id: UUID(),
            fillerID: clip.identity.fillerID,
            cacheKey: cacheKey,
            generation: cached.generation
        )
        ordinal &+= 1
        cached.ordinal = ordinal
        cached.leases.insert(lease.id)
        cache[cacheKey] = cached
        print("[MindEyeFiller] acquired fillerID=\(clip.identity.fillerID) reason=\(reason)")
        return .ready(lease, cached.track)
    }

    func prewarm(
        clip: TuringFillerClipDescriptor,
        expectedSurface: StoryInteractionSurfaceID,
        reason: String
    ) async {
        let cacheKey = "\(clip.identity.fillerID)|\(expectedSurface.rawValue)"
        switch await loadAndCache(
            clip: clip,
            expectedSurface: expectedSurface,
            cacheKey: cacheKey
        ) {
        case .success:
            print("[MindEyeFiller] prewarmed fillerID=\(clip.identity.fillerID) reason=\(reason)")
        case .failure(let failure):
            print(
                "[MindEyeFiller] prewarm unavailable fillerID=\(clip.identity.fillerID) " +
                    "code=\(failure.code.rawValue) audioContinues=true"
            )
        }
    }

    func release(_ lease: MindEyeFillerFrameTrackLease, reason: String) {
        guard var cached = cache[lease.cacheKey],
              cached.generation == lease.generation else { return }
        cached.leases.remove(lease.id)
        cache[lease.cacheKey] = cached
        evictLRU()
        print("[MindEyeFiller] released fillerID=\(lease.fillerID) reason=\(reason)")
    }

    func evictInactive(reason: String) {
        for key in cache.filter({ $0.value.leases.isEmpty }).map(\.key) {
            cache.removeValue(forKey: key)
        }
        print("[MindEyeFiller] inactive tracks evicted reason=\(reason)")
    }

    func forceEvictAll(reason: String) {
        generation &+= 1
        loadEpoch &+= 1
        for value in inFlight.values { value.task.cancel() }
        inFlight.removeAll(keepingCapacity: false)
        cache.removeAll(keepingCapacity: false)
        indexTask?.cancel()
        indexTask = nil
        index = nil
        print("[MindEyeFiller] force evicted reason=\(reason)")
    }

    func snapshot() -> MindEyeFillerFrameTrackStoreSnapshot {
        MindEyeFillerFrameTrackStoreSnapshot(
            cachedFillerIDs: cache.values.map { $0.track.descriptor.prID }.sorted(),
            leasedFillerIDs: cache.values
                .filter { !$0.leases.isEmpty }
                .map { $0.track.descriptor.prID }
                .sorted(),
            loadingFillerIDs: inFlight.keys
                .map { String($0.split(separator: "|", maxSplits: 1)[0]) }
                .sorted(),
            compactByteCount: cache.values.reduce(0) {
                $0 + $1.track.estimatedCompactByteCount
            }
        )
    }

    private func loadAndCache(
        clip: TuringFillerClipDescriptor,
        expectedSurface: StoryInteractionSurfaceID,
        cacheKey: String
    ) async -> Result<MindEyeAuthoredFrameTrack, MindEyeFailure> {
        if let cached = cache[cacheKey] { return .success(cached.track) }
        if let existing = inFlight[cacheKey] {
            let result = await existing.task.value
            return finishLoad(
                result,
                clip: clip,
                cacheKey: cacheKey,
                token: existing.id,
                loadGeneration: existing.generation
            )
        }

        let snapshot: MindEyeFillerFrameIndexSnapshot
        switch await prepareIndex() {
        case .success(let value): snapshot = value
        case .failure(let failure): return .failure(failure)
        }
        guard let entry = snapshot.entriesByFillerID[clip.identity.fillerID] else {
            return .failure(Self.failure(clip, "Filler has no published frame track."))
        }
        let token = UUID()
        let loadGeneration = loadEpoch
        let worker = worker
        let locator = locator
        let task = Task<Result<MindEyeAuthoredFrameTrack, MindEyeFailure>, Never> {
            do {
                return .success(try await worker.loadTrack(
                    entry: entry,
                    clip: clip,
                    expectedSurface: expectedSurface,
                    locator: locator
                ))
            } catch let failure as MindEyeFailure {
                return .failure(failure)
            } catch {
                return .failure(Self.failure(clip, error.localizedDescription))
            }
        }
        inFlight[cacheKey] = InFlight(
            id: token,
            generation: loadGeneration,
            task: task
        )
        let result = await task.value
        return finishLoad(
            result,
            clip: clip,
            cacheKey: cacheKey,
            token: token,
            loadGeneration: loadGeneration
        )
    }

    private func finishLoad(
        _ result: Result<MindEyeAuthoredFrameTrack, MindEyeFailure>,
        clip: TuringFillerClipDescriptor,
        cacheKey: String,
        token: UUID,
        loadGeneration: UInt64
    ) -> Result<MindEyeAuthoredFrameTrack, MindEyeFailure> {
        if let cached = cache[cacheKey] { return .success(cached.track) }
        guard let current = inFlight[cacheKey],
              current.id == token,
              current.generation == loadGeneration,
              loadEpoch == loadGeneration else {
            return .failure(Self.failure(clip, "Filler track load became stale."))
        }
        inFlight.removeValue(forKey: cacheKey)
        if case .success(let track) = result {
            generation &+= 1
            ordinal &+= 1
            cache[cacheKey] = Cached(
                generation: generation,
                track: track,
                leases: [],
                ordinal: ordinal
            )
            evictLRU()
        }
        return result
    }

    private func evictLRU() {
        while cache.count > maximumTracks ||
                cache.values.reduce(0, { $0 + $1.track.estimatedCompactByteCount }) > maximumBytes {
            guard let victim = cache.filter({ $0.value.leases.isEmpty })
                .min(by: { $0.value.ordinal < $1.value.ordinal })?.key else { return }
            cache.removeValue(forKey: victim)
        }
    }

    private static func failure(
        _ clip: TuringFillerClipDescriptor,
        _ message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: .authoredFrameTrackUnavailable,
            characterID: clip.identity.speakerCharacterID,
            vignetteID: nil,
            resourcePath: clip.identity.trackResourcePath,
            message: message
        )
    }

    private static func staleIndexFailure() -> MindEyeFailure {
        MindEyeFailure(
            code: .authoredFrameIndexInvalid,
            characterID: nil,
            vignetteID: nil,
            resourcePath: "Turing/MindsEye/Fillers/index.json",
            message: "Filler frame index load became stale."
        )
    }
}
