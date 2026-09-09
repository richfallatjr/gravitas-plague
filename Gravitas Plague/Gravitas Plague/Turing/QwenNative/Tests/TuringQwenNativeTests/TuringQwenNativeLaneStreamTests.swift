import Foundation
@testable import MLX
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeLaneStreamTests {
    @Test
    func explicitStreamOrDevicePreservesIdentity() {
        let stream = MLX.Stream._taskLocalRoutingPlaceholder()

        #expect(StreamOrDevice.stream(stream).stream === stream)
    }

    @Test
    func defaultModeDoesNotInstallOrOwnAStream() async {
        let baseline = MLX.Stream._taskLocalRoutingPlaceholder()
        let lane = TuringQwenNativeLaneStream(laneID: 0)

        #expect(lane.mode == .defaultOnly)
        #expect(lane.mode == .productionDefault)
        #expect(!lane.ownsDedicatedStream)
        #expect(lane.mlxStream == nil)

        let observed = await MLX.Stream.withDefaultStream(baseline) {
            await lane.withExecutionContext {
                await Task.yield()
                return StreamOrDevice.default.stream
            }
        }

        #expect(observed === baseline)
    }

    @Test
    func dedicatedLanesOwnDistinctStableStreams() async throws {
        let baseline = MLX.Stream._taskLocalRoutingPlaceholder()
        let first = TuringQwenNativeLaneStream(
            laneID: 0,
            mode: .dedicatedGPU,
            makeDedicatedGPUStream: {
                MLX.Stream._taskLocalRoutingPlaceholder()
            }
        )
        let second = TuringQwenNativeLaneStream(
            laneID: 1,
            mode: .dedicatedGPU,
            makeDedicatedGPUStream: {
                MLX.Stream._taskLocalRoutingPlaceholder()
            }
        )

        let firstOwned = try #require(first.mlxStream)
        let secondOwned = try #require(second.mlxStream)
        #expect(first.ownsDedicatedStream)
        #expect(second.ownsDedicatedStream)
        #expect(firstOwned !== secondOwned)

        let observed = await MLX.Stream.withDefaultStream(baseline) {
            let firstObserved = await first.withExecutionContext {
                await Task.yield()
                return StreamOrDevice.default.stream
            }
            let secondObserved = await second.withExecutionContext {
                await Task.yield()
                return StreamOrDevice.default.stream
            }
            #expect(StreamOrDevice.default.stream === baseline)
            return (firstObserved, secondObserved)
        }

        #expect(observed.0 === firstOwned)
        #expect(observed.1 === secondOwned)
    }

    @Test
    func concurrentLaneContextsRemainIsolated() async throws {
        let first = TuringQwenNativeLaneStream(
            laneID: 0,
            mode: .dedicatedGPU,
            makeDedicatedGPUStream: {
                MLX.Stream._taskLocalRoutingPlaceholder()
            }
        )
        let second = TuringQwenNativeLaneStream(
            laneID: 1,
            mode: .dedicatedGPU,
            makeDedicatedGPUStream: {
                MLX.Stream._taskLocalRoutingPlaceholder()
            }
        )
        let firstOwned = try #require(first.mlxStream)
        let secondOwned = try #require(second.mlxStream)

        async let firstObserved = first.withExecutionContext {
            await Task.yield()
            return StreamOrDevice.default.stream
        }
        async let secondObserved = second.withExecutionContext {
            await Task.yield()
            return StreamOrDevice.default.stream
        }

        let observed = await (firstObserved, secondObserved)
        #expect(observed.0 === firstOwned)
        #expect(observed.1 === secondOwned)
    }

    @Test
    func shippingFresh2SourcesDoNotOptIntoDedicatedStreams() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot
            .appendingPathComponent("Sources/TuringQwenNative")
        let shippingSources = [
            "TuringQwenNativeGenerationSchedulerFactory.swift",
            "TuringQwenNativeFreshInstancePool.swift",
            "TuringQwenNativeFreshInstanceScheduler.swift",
        ]

        for sourceName in shippingSources {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(sourceName),
                encoding: .utf8
            )
            #expect(!source.contains("dedicatedGPU"))
            #expect(!source.contains("TuringQwenNativeLaneStream"))
        }

        let laneStreamSource = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "TuringQwenNativeLaneStream.swift"
            ),
            encoding: .utf8
        )
        #expect(laneStreamSource.contains("MLX.Stream(.gpu)"))
        #expect(laneStreamSource.contains("MLX.Stream.withDefaultStream"))
    }
}
