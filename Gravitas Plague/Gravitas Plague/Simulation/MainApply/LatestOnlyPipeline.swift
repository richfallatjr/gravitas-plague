import Foundation

@MainActor
final class LatestOnlyPipeline<Request: Sendable, Output: Sendable> {
    typealias Operation = @Sendable (Request) async -> Output

    private let operation: Operation

    private var inFlight: Task<Void, Never>?
    private var pendingRequest: Request?
    private var latestCompletedOutput: Output?

    init(
        operation: @escaping Operation
    ) {
        self.operation = operation
    }

    var isBusy: Bool {
        inFlight != nil
    }

    func submitLatest(
        _ request: Request
    ) {
        // Latest request replaces any request that has not started.
        pendingRequest = request
        startNextIfNeeded()
    }

    func takeLatestCompleted() -> Output? {
        defer {
            latestCompletedOutput = nil
        }

        return latestCompletedOutput
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        pendingRequest = nil
        latestCompletedOutput = nil
    }

    private func startNextIfNeeded() {
        guard inFlight == nil,
              let request = pendingRequest else {
            return
        }

        pendingRequest = nil

        let operation = self.operation

        inFlight = Task { [weak self] in
            let output = await operation(request)

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self else {
                    return
                }

                self.latestCompletedOutput = output
                self.inFlight = nil
                self.startNextIfNeeded()
            }
        }
    }
}
