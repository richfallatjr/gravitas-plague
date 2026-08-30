import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeFreshLaneCancellationTests {
    private enum ExpectedFailure: Error {
        case terminal
    }

    private actor CancellationObservation {
        private(set) var siblingObservedCancellation = false

        func recordCancellation() {
            siblingObservedCancellation = true
        }
    }

    @Test
    func firstLaneFailureCancelsSiblingWithoutWaitingForLaneOrder() async {
        let observation = CancellationObservation()

        await #expect(throws: ExpectedFailure.self) {
            try await TuringQwenNativeFreshInstanceScheduler.runLaneOperations([
                {
                    do {
                        while true {
                            try Task.checkCancellation()
                            await Task.yield()
                        }
                    } catch is CancellationError {
                        await observation.recordCancellation()
                        throw CancellationError()
                    }
                },
                {
                    throw ExpectedFailure.terminal
                }
            ])
        }

        #expect(await observation.siblingObservedCancellation)
    }
}
