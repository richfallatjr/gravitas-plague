import Foundation

@MainActor
final class TuringFillerSideLaneCoordinator {
    private struct Policy: Sendable {
        var firstSegmentPrerollFillerCount: Int = 1
        var chainFillerWhileComputeWithoutSpeech: Bool = true
        var deadAirAfterFillerEnabled: Bool = true
        var deadAirMinSeconds: Double = 0.5
        var deadAirMaxSeconds: Double = 4.0
    }

    private enum FillerReason: String {
        case firstSegmentPreroll
        case computeWithoutSpeech
    }

    private let policy = Policy()
    private weak var sink: TuringQueuedPlaybackSink?
    private var onPlaybackMayProceed: (@MainActor @Sendable () async -> Void)?

    private let fillerDirectoryCandidates = [
        "Turing/Audio/big-mike-filler",
        "Turing/big-mike-filler",
        "big-mike-filler"
    ]
    private let fillerExtensions: Set<String> = [
        "wav",
        "mp3",
        "m4a",
        "aiff",
        "caf"
    ]
    private var fillerFiles: [URL] = []
    private var fillerQueue: [URL] = []
    private var lastFillerFile: URL?

    private var runActive = false
    private var expectedSegmentCount: Int?
    private var computeInFlight = Set<Int>()
    private var readyGeneratedIndexes = Set<Int>()
    private var nextRequiredSegmentIndex = 0
    private var generatedPlaying = false
    private var allComputeFinished = false
    private var firstSegmentPrerollRemaining = 0
    private var activeFillerHandle: TuringPlaybackHandle?
    private var activeFillerFile: URL?
    private var fillerTask: Task<Void, Never>?
    private var deadAirTask: Task<Void, Never>?
    private var fillerChainCount = 0

    var shouldDeferGeneratedPlayback: Bool {
        activeFillerHandle != nil
    }

    init() {
        self.fillerFiles = Self.discoverFillerFiles(
            candidates: fillerDirectoryCandidates,
            allowedExtensions: fillerExtensions
        )
        rebuildFillerQueue()

        print("""
        [TuringFillerSideLane] initialized
          fillerClipCount: \(Set(fillerFiles).count)
          weightedFillerEntryCount: \(fillerFiles.count)
          firstSegmentPrerollFillerCount: \(policy.firstSegmentPrerollFillerCount)
          chainFillerWhileComputeWithoutSpeech: \(policy.chainFillerWhileComputeWithoutSpeech)
          deadAirAfterFiller: \(policy.deadAirAfterFillerEnabled)
          deadAirSeconds: \(String(format: "%.2f", policy.deadAirMinSeconds))...\(String(format: "%.2f", policy.deadAirMaxSeconds))
        """)
    }

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?,
        sink: TuringQueuedPlaybackSink,
        onPlaybackMayProceed: (@MainActor @Sendable () async -> Void)? = nil
    ) async {
        await runCancelled(reason: "beginNewRun")
        self.sink = sink
        self.onPlaybackMayProceed = onPlaybackMayProceed
        self.expectedSegmentCount = expectedSegmentCount
        self.computeInFlight.removeAll(keepingCapacity: true)
        self.readyGeneratedIndexes.removeAll(keepingCapacity: true)
        self.nextRequiredSegmentIndex = 0
        self.generatedPlaying = false
        self.allComputeFinished = false
        self.firstSegmentPrerollRemaining = policy.firstSegmentPrerollFillerCount
        self.fillerChainCount = 0
        self.runActive = true

        print("""
        [TuringFillerSideLane] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          fillerClipCount: \(Set(fillerFiles).count)
          owner: fillerOnly
          generatedSpeechOwner: TuringWAVQueue
        """)
    }

    func updateNextRequiredSegmentIndex(_ segmentIndex: Int) async {
        guard runActive else { return }
        nextRequiredSegmentIndex = segmentIndex
        print("""
        [TuringFillerSideLane] next required segment updated
          nextRequiredSegmentIndex: \(nextRequiredSegmentIndex)
          readyGeneratedIndexes: \(readyGeneratedIndexes.sorted().map(String.init).joined(separator: ","))
        """)
        await reconcile(reason: "nextRequiredSegmentUpdated")
    }

    func qwenComputeStarted(segmentIndex: Int) async {
        guard runActive else { return }
        computeInFlight.insert(segmentIndex)
        print("""
        [TuringFillerSideLane] qwen compute started
          segmentIndex: \(segmentIndex)
          computeInFlight: \(computeInFlight.sorted().map(String.init).joined(separator: ","))
        """)
        await reconcile(reason: "qwenComputeStarted")
    }

    func generatedWAVPublished(segmentIndex: Int) async {
        guard runActive else { return }
        computeInFlight.remove(segmentIndex)
        readyGeneratedIndexes.insert(segmentIndex)
        stopDeadAir(reason: "generatedWAVPublished")
        print("""
        [TuringFillerSideLane] generatedWAVPublished
          segmentIndex: \(segmentIndex)
          readyGeneratedIndexes: \(readyGeneratedIndexes.sorted().map(String.init).joined(separator: ","))
          ownsGeneratedSpeech: false
        """)
        await reconcile(reason: "generatedWAVPublished")
    }

    func qwenComputeSkipped(
        segmentIndex: Int,
        reason: String
    ) async {
        guard runActive else { return }
        computeInFlight.remove(segmentIndex)
        stopDeadAir(reason: "qwenComputeSkipped")
        print("""
        [TuringFillerSideLane] qwen compute skipped
          segmentIndex: \(segmentIndex)
          reason: \(reason)
          computeInFlight: \(computeInFlight.sorted().map(String.init).joined(separator: ","))
        """)
        await reconcile(reason: "qwenComputeSkipped")
    }

    func generatedPlaybackStarted(segmentIndex: Int) async {
        guard runActive else { return }
        readyGeneratedIndexes.remove(segmentIndex)
        generatedPlaying = true
        stopDeadAir(reason: "generatedPlaybackStarted")
        print("""
        [TuringFillerSideLane] generatedPlaybackStarted
          segmentIndex: \(segmentIndex)
          schedulingFutureFiller: false
        """)
    }

    func generatedPlaybackFinished(segmentIndex: Int) async {
        guard runActive else { return }
        generatedPlaying = false
        fillerChainCount = 0
        print("""
        [TuringFillerSideLane] generatedPlaybackFinished
          segmentIndex: \(segmentIndex)
        """)
        await reconcile(reason: "generatedPlaybackFinished")
    }

    func qwenComputeAllFinished() async {
        guard runActive else { return }
        allComputeFinished = true
        print("[TuringFillerSideLane] qwen compute all finished")
        await reconcile(reason: "qwenComputeAllFinished")
    }

    func runCancelled(reason: String) async {
        guard runActive ||
                activeFillerHandle != nil ||
                deadAirTask != nil else { return }
        runActive = false
        fillerTask?.cancel()
        fillerTask = nil
        deadAirTask?.cancel()
        deadAirTask = nil
        activeFillerHandle = nil
        activeFillerFile = nil
        computeInFlight.removeAll(keepingCapacity: false)
        readyGeneratedIndexes.removeAll(keepingCapacity: false)
        generatedPlaying = false
        allComputeFinished = false
        onPlaybackMayProceed = nil
        print("""
        [TuringFillerSideLane] run cancelled
          reason: \(reason)
        """)
    }

    private func reconcile(reason: String) async {
        guard runActive else { return }
        guard generatedPlaying == false else { return }
        guard activeFillerHandle == nil else { return }
        guard deadAirTask == nil else { return }

        if firstSegmentPrerollRemaining > 0,
           nextRequiredSegmentIndex == 0,
           readyGeneratedIndexes.contains(nextRequiredSegmentIndex) {
            firstSegmentPrerollRemaining -= 1
            await startFiller(reason: .firstSegmentPreroll)
            return
        }

        if readyGeneratedIndexes.contains(nextRequiredSegmentIndex) {
            return
        }

        guard policy.chainFillerWhileComputeWithoutSpeech,
              computeInFlight.isEmpty == false,
              allComputeFinished == false else {
            return
        }

        await startFiller(reason: .computeWithoutSpeech)
    }

    private func startFiller(reason: FillerReason) async {
        guard let sink else {
            print("""
            [TuringFillerSideLane] filler unavailable
              reason: \(reason.rawValue)
              detail: missingSink
            """)
            return
        }

        guard let file = nextFillerFile() else {
            print("""
            [TuringFillerSideLane] filler unavailable
              reason: \(reason.rawValue)
              detail: noClips
            """)
            return
        }

        do {
            let label = file.deletingPathExtension().lastPathComponent
            let handle = try await sink.playFillerClip(
                fileURL: file,
                label: label
            )
            activeFillerHandle = handle
            activeFillerFile = file
            lastFillerFile = file

            let chainLog = fillerChainCount > 0 &&
                reason == .computeWithoutSpeech
            if chainLog {
                print("""
                [TuringFillerSideLane] filler chained
                  reason: \(reason.rawValue)
                  file: \(file.lastPathComponent)
                  ownsGeneratedSpeech: false
                """)
            }
            print("""
            [TuringFillerSideLane] filler started
              reason: \(reason.rawValue)
              file: \(file.lastPathComponent)
              nonInterruptibleByGeneratedReady: true
              ownsGeneratedSpeech: false
            """)
            fillerChainCount += 1

            fillerTask = Task { @MainActor [weak self, sink] in
                await sink.waitForPlaybackCompletion(handle)
                guard Task.isCancelled == false else { return }
                await self?.fillerPlaybackFinished(
                    file: file,
                    handleID: handle.id
                )
            }
        } catch {
            print("""
            [TuringFillerSideLane] filler start failed
              reason: \(reason.rawValue)
              error: \(error.localizedDescription)
            """)
        }
    }

    private func fillerPlaybackFinished(
        file: URL,
        handleID: UUID
    ) async {
        guard let activeFillerHandle,
              activeFillerHandle.id == handleID else {
            print("""
            [TuringFillerSideLane] stale filler completion ignored
              callbackHandleID: \(handleID.uuidString)
              activeHandleID: \(self.activeFillerHandle?.id.uuidString ?? "nil")
            """)
            return
        }

        self.activeFillerHandle = nil
        self.activeFillerFile = nil
        self.fillerTask = nil

        print("""
        [TuringFillerSideLane] filler finished
          file: \(file.lastPathComponent)
        """)

        if readyGeneratedIndexes.contains(nextRequiredSegmentIndex) {
            await onPlaybackMayProceed?()
            return
        }

        if policy.deadAirAfterFillerEnabled,
           computeInFlight.isEmpty == false,
           readyGeneratedIndexes.contains(nextRequiredSegmentIndex) == false,
           generatedPlaying == false {
            startDeadAir(reason: "afterFiller")
            return
        }

        await reconcile(reason: "fillerFinished")
    }

    private func startDeadAir(reason: String) {
        guard deadAirTask == nil else { return }
        let seconds = Double.random(
            in: policy.deadAirMinSeconds...policy.deadAirMaxSeconds
        )
        print("""
        [TuringFillerSideLane] dead air started
          reason: \(reason)
          seconds: \(String(format: "%.2f", seconds))
          isAudio: false
        """)

        deadAirTask = Task { @MainActor [weak self] in
            let nanos = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard Task.isCancelled == false else { return }
            await self?.deadAirFinished(seconds: seconds)
        }
    }

    private func deadAirFinished(seconds: Double) async {
        deadAirTask = nil
        print("""
        [TuringFillerSideLane] dead air finished
          seconds: \(String(format: "%.2f", seconds))
        """)
        if readyGeneratedIndexes.contains(nextRequiredSegmentIndex) {
            await onPlaybackMayProceed?()
            return
        }
        await reconcile(reason: "deadAirFinished")
    }

    private func stopDeadAir(reason: String) {
        guard let deadAirTask else { return }
        deadAirTask.cancel()
        self.deadAirTask = nil
        print("""
        [TuringFillerSideLane] dead air stopped
          reason: \(reason)
        """)
    }

    private func nextFillerFile() -> URL? {
        if fillerQueue.isEmpty {
            rebuildFillerQueue()
        }
        guard fillerQueue.isEmpty == false else { return nil }
        return fillerQueue.removeFirst()
    }

    private func rebuildFillerQueue() {
        fillerQueue = fillerFiles.shuffled()
        if fillerQueue.count > 1,
           let lastFillerFile,
           fillerQueue.first == lastFillerFile {
            fillerQueue.append(fillerQueue.removeFirst())
        }
    }

    private static func discoverFillerFiles(
        candidates: [String],
        allowedExtensions: Set<String>
    ) -> [URL] {
        var weighted: [URL] = []

        for candidate in candidates {
            guard let directory = Bundle.main.url(
                forResource: candidate,
                withExtension: nil
            ) else {
                continue
            }

            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard allowedExtensions.contains(file.pathExtension.lowercased()) else {
                    continue
                }
                weighted.append(
                    contentsOf: Array(
                        repeating: file,
                        count: fillerWeight(for: file)
                    )
                )
            }
        }

        return weighted
    }

    private static func fillerWeight(for file: URL) -> Int {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let raw = stem.split(separator: "_").last,
              let parsed = Int(raw) else {
            return 1
        }
        return min(max(parsed, 1), 10)
    }
}
