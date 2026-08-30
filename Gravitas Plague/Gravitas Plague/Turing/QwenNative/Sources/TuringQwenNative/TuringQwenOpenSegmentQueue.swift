import Foundation

public actor TuringQwenOpenSegmentQueue {
    public enum QueueError: LocalizedError, Sendable {
        case sealed
        case cancelled(String)

        public var errorDescription: String? {
            switch self {
            case .sealed:
                return "The Qwen segment queue is sealed."
            case .cancelled(let reason):
                return "The Qwen segment queue was cancelled: \(reason)"
            }
        }
    }

    private var requests: [TuringQwenNativeBaseCloneSegmentRequest] = []
    private var waiters: [
        CheckedContinuation<TuringQwenNativeBaseCloneSegmentRequest?, Error>
    ] = []
    private var submittedIndices = Set<Int>()
    private var isSealed = false
    private var cancellationReason: String?

    public init() {}

    public func append(
        _ newRequests: [TuringQwenNativeBaseCloneSegmentRequest]
    ) throws {
        if let cancellationReason {
            throw QueueError.cancelled(cancellationReason)
        }
        guard isSealed == false else {
            throw QueueError.sealed
        }

        var pendingIndices = submittedIndices
        for request in newRequests {
            guard pendingIndices.insert(request.segmentIndex).inserted else {
                throw TuringQwenNativeError.invalidConfig(
                    "Duplicate global segment index \(request.segmentIndex)."
                )
            }
        }
        submittedIndices = pendingIndices

        for request in newRequests {
            if waiters.isEmpty {
                requests.append(request)
            } else {
                waiters.removeFirst().resume(returning: request)
            }
        }
    }

    public func next()
        async throws -> TuringQwenNativeBaseCloneSegmentRequest?
    {
        if let cancellationReason {
            throw QueueError.cancelled(cancellationReason)
        }
        if requests.isEmpty == false {
            return requests.removeFirst()
        }
        if isSealed {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func seal() {
        guard isSealed == false, cancellationReason == nil else { return }
        isSealed = true
        let current = waiters
        waiters.removeAll(keepingCapacity: false)
        current.forEach { $0.resume(returning: nil) }
    }

    public func cancel(reason: String) {
        guard cancellationReason == nil else { return }
        cancellationReason = reason
        requests.removeAll(keepingCapacity: false)
        let current = waiters
        waiters.removeAll(keepingCapacity: false)
        current.forEach {
            $0.resume(throwing: QueueError.cancelled(reason))
        }
    }

    public func depth() -> Int {
        requests.count
    }

    public func submittedCount() -> Int {
        submittedIndices.count
    }

    public func recoveryCancellationIsComplete() -> Bool {
        cancellationReason != nil && requests.isEmpty && waiters.isEmpty
    }
}
