import Foundation

public struct TuringQwenRenderDecodeOverlapMetrics: Sendable, Equatable {
    public let peakActiveRenderCount: Int
    public let sameSegmentRenderDecodeOverlapCount: Int
    public let crossSegmentRenderDecodeOverlapCount: Int
}

public struct TuringQwenDecodeAcquireObservation: Sendable, Equatable {
    public let activeRenderCount: Int
    public let sameSegmentRenderActive: Bool
    public let crossSegmentRenderActive: Bool
    public let activeRenderKeys: [String]
}

public struct TuringQwenActiveRenderSnapshot: Sendable, Equatable {
    public let activeRenderCount: Int
    public let activeRenderKeys: [String]
}

public actor TuringQwenRenderPhaseState {
    private struct ActiveRender: Hashable {
        let runID: String
        let segmentIndex: Int
        let instanceID: TuringQwenNativeFreshInstanceID
    }

    private var activeRenders = Set<ActiveRender>()
    private var peakActiveRenderCount = 0
    private var sameSegmentRenderDecodeOverlapCount = 0
    private var crossSegmentRenderDecodeOverlapCount = 0

    public init() {}

    public func beginRun(runID: String) throws {
        guard activeRenders.isEmpty else {
            throw TuringQwenNativeError.invalidConfig(
                "Cannot begin \(runID) while a prior render remains active."
            )
        }
        peakActiveRenderCount = 0
        sameSegmentRenderDecodeOverlapCount = 0
        crossSegmentRenderDecodeOverlapCount = 0
    }

    public func renderStarted(
        runID: String,
        segmentIndex: Int,
        instanceID: TuringQwenNativeFreshInstanceID
    ) {
        activeRenders.insert(
            ActiveRender(
                runID: runID,
                segmentIndex: segmentIndex,
                instanceID: instanceID
            )
        )
        peakActiveRenderCount = max(peakActiveRenderCount, activeRenders.count)
        print("""
        [TuringSegmentPipeline] render phase entered
          runID: \(runID)
          segmentIndex: \(segmentIndex)
          instanceID: \(instanceID.rawValue)
          activeRenderCount: \(activeRenders.count)
        """)
    }

    public func renderReleased(
        runID: String,
        segmentIndex: Int,
        instanceID: TuringQwenNativeFreshInstanceID
    ) {
        let removed = activeRenders.remove(
            ActiveRender(
                runID: runID,
                segmentIndex: segmentIndex,
                instanceID: instanceID
            )
        )
        precondition(removed != nil, "Render phase released more than once.")
        print("""
        [TuringSegmentPipeline] render phase released
          runID: \(runID)
          segmentIndex: \(segmentIndex)
          instanceID: \(instanceID.rawValue)
          activeRenderCount: \(activeRenders.count)
        """)
    }

    public func decodeAcquired(
        runID: String,
        segmentIndex: Int
    ) -> TuringQwenDecodeAcquireObservation {
        let sameSegmentActive = activeRenders.contains {
            $0.runID == runID && $0.segmentIndex == segmentIndex
        }
        let otherSegmentActive = activeRenders.contains {
            $0.runID == runID && $0.segmentIndex != segmentIndex
        }
        if sameSegmentActive {
            sameSegmentRenderDecodeOverlapCount += 1
        }
        if otherSegmentActive {
            crossSegmentRenderDecodeOverlapCount += 1
        }
        let keys = activeRenders.map {
            "\($0.runID).\($0.segmentIndex).\($0.instanceID.rawValue)"
        }.sorted()
        return TuringQwenDecodeAcquireObservation(
            activeRenderCount: activeRenders.count,
            sameSegmentRenderActive: sameSegmentActive,
            crossSegmentRenderActive: otherSegmentActive,
            activeRenderKeys: keys
        )
    }

    public func snapshot() -> TuringQwenRenderDecodeOverlapMetrics {
        TuringQwenRenderDecodeOverlapMetrics(
            peakActiveRenderCount: peakActiveRenderCount,
            sameSegmentRenderDecodeOverlapCount: sameSegmentRenderDecodeOverlapCount,
            crossSegmentRenderDecodeOverlapCount: crossSegmentRenderDecodeOverlapCount
        )
    }

    public func activeSnapshot() -> TuringQwenActiveRenderSnapshot {
        let keys = activeRenders.map {
            "\($0.runID).\($0.segmentIndex).\($0.instanceID.rawValue)"
        }.sorted()
        return TuringQwenActiveRenderSnapshot(
            activeRenderCount: activeRenders.count,
            activeRenderKeys: keys
        )
    }
}
