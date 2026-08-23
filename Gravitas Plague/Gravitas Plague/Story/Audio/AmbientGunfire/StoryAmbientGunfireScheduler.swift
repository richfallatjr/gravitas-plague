import Foundation

actor StoryAmbientGunfireScheduler {
    private let channel: StoryAmbientGroundChannel
    private let catalog: StoryAmbientGunfireCatalog
    private let snapshotProvider: StoryAmbientGunfireWorldSnapshotProvider
    private let worldBridge: StoryAmbientGunfireWorldBridge
    private let resourceLoader: TuringRealityAudioResourceLoader
    private let random: any StoryAmbientGunfireRandomSource
    private let clock: any StoryAmbientGunfireClock

    private var activeSessionID: StoryAmbientGunfireSessionID?
    private var runTask: Task<Void, Never>?
    private var lastAssetID: String?

    init(
        channel: StoryAmbientGroundChannel = .gunfire,
        catalog: StoryAmbientGunfireCatalog,
        snapshotProvider: StoryAmbientGunfireWorldSnapshotProvider,
        worldBridge: StoryAmbientGunfireWorldBridge,
        resourceLoader: TuringRealityAudioResourceLoader = .shared,
        random: any StoryAmbientGunfireRandomSource = SystemStoryAmbientGunfireRandomSource(),
        clock: any StoryAmbientGunfireClock = ContinuousStoryAmbientGunfireClock()
    ) {
        self.channel = channel
        self.catalog = catalog
        self.snapshotProvider = snapshotProvider
        self.worldBridge = worldBridge
        self.resourceLoader = resourceLoader
        self.random = random
        self.clock = clock
    }

    func activate(reason: String) {
        guard runTask == nil, activeSessionID == nil else { return }
        let sessionID = StoryAmbientGunfireSessionID(rawValue: UUID())
        activeSessionID = sessionID
        runTask = Task { [weak self] in
            await self?.run(sessionID: sessionID)
        }
        print(
            "[\(channel.logName)] activated " +
                "sessionID=\(sessionID.rawValue.uuidString) reason=\(reason)"
        )
    }

    func suspend(reason: String) async {
        guard activeSessionID != nil || runTask != nil else {
            await worldBridge.stopActive(reason: reason)
            return
        }
        let task = runTask
        let sessionID = activeSessionID
        activeSessionID = nil
        runTask = nil
        task?.cancel()
        await worldBridge.stopActive(reason: reason)
        await task?.value
        print(
            "[\(channel.logName)] suspended " +
                "sessionID=\(sessionID?.rawValue.uuidString ?? "none") " +
                "reason=\(reason)"
        )
    }

    private func run(sessionID: StoryAmbientGunfireSessionID) async {
        while !Task.isCancelled, activeSessionID == sessionID {
            let gap = StoryAmbientGunfireSpatialSampler.gapSeconds(
                catalog: catalog,
                unit: await random.nextUnitInterval()
            )
            do {
                try await clock.sleep(seconds: gap)
                try Task.checkCancellation()
                guard activeSessionID == sessionID else { return }
                try await playNext(sessionID: sessionID, precedingGapSeconds: gap)
            } catch is CancellationError {
                return
            } catch {
                print(
                    "[\(channel.logName)] event failed " +
                        "sessionID=\(sessionID.rawValue.uuidString) " +
                        "error=\(error.localizedDescription) nextAction=freshGap"
                )
            }
        }
    }

    private func playNext(
        sessionID: StoryAmbientGunfireSessionID,
        precedingGapSeconds: Double
    ) async throws {
        let asset = await selectAsset()
        let azimuth = StoryAmbientGunfireSpatialSampler.azimuthRadians(
            unit: await random.nextUnitInterval()
        )
        let radius = StoryAmbientGunfireSpatialSampler.radiusFeet(
            assetClass: asset.assetClass,
            catalog: catalog,
            unit: await random.nextUnitInterval()
        )
        let snapshot = try await snapshotProvider.capture()
        let worldPosition = StoryAmbientGunfireSpatialSampler.worldPosition(
            snapshot: snapshot,
            azimuthRadians: azimuth,
            radiusFeet: radius,
            groundOffsetMeters: catalog.groundOffsetMeters
        )
        let fileURL = try TuringResourceLoader.resourceURL(
            resourcePath: "\(channel.resourceDirectory)/\(asset.fileName)"
        )
        let prepared = try await resourceLoader.load(
            fileURL: fileURL,
            shouldLoop: false,
            cachePolicy: .transient
        )
        let request = StoryAmbientGunfirePlaybackRequest(
            sessionID: sessionID,
            eventID: .init(rawValue: UUID()),
            asset: asset,
            worldPosition: worldPosition,
            azimuthRadians: azimuth,
            radiusFeet: radius,
            floorSource: snapshot.floorSource
        )

        do {
            try Task.checkCancellation()
            guard activeSessionID == sessionID else {
                throw CancellationError()
            }
            StoryAmbientGunfireTelemetry.eventStarted(
                request: request,
                precedingGapSeconds: precedingGapSeconds,
                channel: channel
            )
            try await worldBridge.playAndWait(
                prepared: prepared,
                request: request
            )
            await resourceLoader.evictTransient(fileURL: fileURL)
            lastAssetID = asset.id
            StoryAmbientGunfireTelemetry.eventCompleted(
                request: request,
                channel: channel
            )
        } catch {
            await worldBridge.stopActive(reason: "eventFailed")
            await resourceLoader.evictTransient(fileURL: fileURL)
            throw error
        }
    }

    private func selectAsset() async -> StoryAmbientGunfireAsset {
        let candidates: [StoryAmbientGunfireAsset]
        if catalog.avoidImmediateRepeat,
           catalog.assets.count > 1,
           let lastAssetID {
            candidates = catalog.assets.filter { $0.id != lastAssetID }
        } else {
            candidates = catalog.assets
        }

        let totalWeight = candidates.reduce(0) { $0 + $1.selectionWeight }
        let target = await random.nextUnitInterval() * totalWeight
        var cursor = 0.0
        for asset in candidates {
            cursor += asset.selectionWeight
            if target < cursor { return asset }
        }
        return candidates[candidates.index(before: candidates.endIndex)]
    }
}
