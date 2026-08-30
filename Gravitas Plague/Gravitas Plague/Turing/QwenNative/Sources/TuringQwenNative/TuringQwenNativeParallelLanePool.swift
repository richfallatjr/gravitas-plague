import Foundation

@available(
    *,
    deprecated,
    message: "Production Turing uses Fresh2 with explicit residency ownership."
)
public actor TuringQwenNativeParallelLanePool {
    public let laneCountRequested: Int
    public private(set) var laneCountActive: Int
    public let residentResources: TuringQwenNativeResidentResources
    public let memoryPolicy: TuringQwenNativeParallelMemoryPolicy
    private let lanes: [TuringQwenNativeGenerationLane]

    public init(
        modelRoot: URL,
        laneCountRequested: Int,
        memoryPolicy: TuringQwenNativeParallelMemoryPolicy = TuringQwenNativeParallelMemoryPolicy()
    ) throws {
        self.laneCountRequested = max(1, laneCountRequested)
        self.memoryPolicy = memoryPolicy
        let resident = try TuringQwenNativeResidentResources(modelRoot: modelRoot)
        self.residentResources = resident
        let active = Self.admittedLaneCount(
            requested: max(1, laneCountRequested),
            policy: memoryPolicy
        )
        self.laneCountActive = active
        self.lanes = try (0..<active).map { laneID in
            try TuringQwenNativeGenerationLane(
                laneID: laneID,
                residentResources: resident
            )
        }

        if active < laneCountRequested {
            print("""
            [TuringQwenParallel] requested lane disabled by memory guard
              laneCountRequested: \(laneCountRequested)
              laneCountActive: \(active)
            """)
        }

        print("""
        [TuringQwenParallel] lane pool ready
          parallelQwenLanes: \(laneCountRequested)
          parallelQwenMode: inProcessSharedWeightsDefaultStream
          laneCountActive: \(active)
          sharedWeights: true
          memoryGuardDowngraded: \(active < laneCountRequested)
        """)
    }

    public func render(
        request: TuringQwenNativeBaseCloneSegmentRequest,
        laneID: Int
    ) async throws -> TuringQwenNativeGeneratedAudio {
        let laneIndex = min(max(0, laneID), max(0, lanes.count - 1))
        return try await lanes[laneIndex].renderSegment(request)
    }

    public func releaseResidentResources(
        reason: String
    ) async {
        for lane in lanes {
            await lane.releaseResidentState(reason: reason)
        }
        print("""
        [TuringQwenParallel] residentResources released
          reason: \(reason)
          sharedWeights: true
        """)
    }

    private static func admittedLaneCount(
        requested: Int,
        policy: TuringQwenNativeParallelMemoryPolicy
    ) -> Int {
        guard requested > 1 else {
            return 1
        }

        let memory = TuringQwenNativeParallelPerfReport.memorySnapshotMegabytes()
        if memory.active > Double(policy.maxMLXActiveMemoryMB) ||
            memory.cache > Double(policy.maxMLXCacheMemoryMB) {
            return 1
        }

        return min(requested, 3)
    }
}
