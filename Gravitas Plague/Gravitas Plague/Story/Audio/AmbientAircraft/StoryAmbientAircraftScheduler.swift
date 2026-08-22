import Foundation

actor StoryAmbientAircraftScheduler {
    private let catalog: StoryAmbientAircraftCatalog
    private let worldBridge: StoryAmbientAircraftWorldBridge
    private let resourceLoader: TuringRealityAudioResourceLoader
    private let random: any StoryAmbientGunfireRandomSource
    private let clock: any StoryAmbientGunfireClock

    private var activeSessionID: StoryAmbientAircraftSessionID?
    private var runTask: Task<Void, Never>?

    init(
        catalog: StoryAmbientAircraftCatalog,
        worldBridge: StoryAmbientAircraftWorldBridge,
        resourceLoader: TuringRealityAudioResourceLoader = .shared,
        random: any StoryAmbientGunfireRandomSource = SystemStoryAmbientGunfireRandomSource(),
        clock: any StoryAmbientGunfireClock = ContinuousStoryAmbientGunfireClock()
    ) {
        self.catalog = catalog
        self.worldBridge = worldBridge
        self.resourceLoader = resourceLoader
        self.random = random
        self.clock = clock
    }

    func activate(reason: String) {
        guard runTask == nil, activeSessionID == nil else { return }
        let sessionID = StoryAmbientAircraftSessionID(rawValue: UUID())
        activeSessionID = sessionID
        runTask = Task { [weak self] in
            await self?.run(sessionID: sessionID)
        }
        print(
            "[StoryAmbientAircraft] activated " +
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
            "[StoryAmbientAircraft] suspended " +
                "sessionID=\(sessionID?.rawValue.uuidString ?? "none") " +
                "reason=\(reason)"
        )
    }

    private func run(sessionID: StoryAmbientAircraftSessionID) async {
        while !Task.isCancelled, activeSessionID == sessionID {
            let gap = StoryAmbientAircraftSampler.gapSeconds(
                catalog: catalog,
                unit: await random.nextUnitInterval()
            )
            do {
                try await clock.sleep(seconds: gap)
                try Task.checkCancellation()
                guard activeSessionID == sessionID else { return }
                try await playNext(
                    sessionID: sessionID,
                    precedingGapSeconds: gap
                )
            } catch is CancellationError {
                return
            } catch {
                print(
                    "[StoryAmbientAircraft] event failed " +
                        "sessionID=\(sessionID.rawValue.uuidString) " +
                        "error=\(error.localizedDescription) nextAction=freshGap"
                )
            }
        }
    }

    private func playNext(
        sessionID: StoryAmbientAircraftSessionID,
        precedingGapSeconds: Double
    ) async throws {
        let asset = await selectAsset()
        let heightFeet = StoryAmbientAircraftSampler.heightFeet(
            catalog: catalog,
            unit: await random.nextUnitInterval()
        )
        let fileURL = try TuringResourceLoader.resourceURL(
            resourcePath: "Turing/Audio/story-ambient-aircraft/\(asset.fileName)"
        )
        let prepared = try await resourceLoader.load(
            fileURL: fileURL,
            shouldLoop: false,
            cachePolicy: .transient
        )
        let request = StoryAmbientAircraftPlaybackRequest(
            sessionID: sessionID,
            eventID: .init(rawValue: UUID()),
            asset: asset,
            worldPosition: StoryAmbientAircraftSampler.worldPosition(
                heightFeet: heightFeet
            ),
            heightFeet: heightFeet,
            sourceGainDB: catalog.sourceGainDB,
            distanceRolloffFactor: catalog.distanceRolloffFactor
        )

        do {
            try Task.checkCancellation()
            guard activeSessionID == sessionID else {
                throw CancellationError()
            }
            StoryAmbientAircraftTelemetry.eventStarted(
                request: request,
                precedingGapSeconds: precedingGapSeconds
            )
            try await worldBridge.playAndWait(
                prepared: prepared,
                request: request
            )
            await resourceLoader.evictTransient(fileURL: fileURL)
            StoryAmbientAircraftTelemetry.eventCompleted(request: request)
        } catch {
            await worldBridge.stopActive(reason: "eventFailed")
            await resourceLoader.evictTransient(fileURL: fileURL)
            throw error
        }
    }

    private func selectAsset() async -> StoryAmbientAircraftAsset {
        let totalWeight = catalog.assets.reduce(0) {
            $0 + $1.selectionWeight
        }
        let target = await random.nextUnitInterval() * totalWeight
        var cursor = 0.0
        for asset in catalog.assets {
            cursor += asset.selectionWeight
            if target < cursor { return asset }
        }
        return catalog.assets[catalog.assets.index(before: catalog.assets.endIndex)]
    }
}
