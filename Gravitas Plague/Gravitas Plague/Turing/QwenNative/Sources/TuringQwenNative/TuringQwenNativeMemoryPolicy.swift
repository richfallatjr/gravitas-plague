import Foundation

public struct TuringQwenNativeMemoryPolicy: Sendable, Equatable {
    public let cacheLimitBytes: Int?
    public let memoryLimitBytes: Int?
    public let clearCacheAfterSegment: Bool
    public let clearCacheEveryNRows: Int?
    public let snapshotEveryNRows: Int?

    public static let performance = TuringQwenNativeMemoryPolicy(
        cacheLimitBytes: 64 * 1024 * 1024,
        memoryLimitBytes: nil,
        clearCacheAfterSegment: true,
        clearCacheEveryNRows: nil,
        snapshotEveryNRows: 8
    )

    public static let diagnostic = TuringQwenNativeMemoryPolicy(
        cacheLimitBytes: 64 * 1024 * 1024,
        memoryLimitBytes: nil,
        clearCacheAfterSegment: true,
        clearCacheEveryNRows: 1,
        snapshotEveryNRows: 1
    )

    public static func forMode(
        _ mode: TuringQwenNativePerformanceMode
    ) -> TuringQwenNativeMemoryPolicy {
        switch mode {
        case .diagnostic:
            return .diagnostic
        case .performance:
            return .performance
        }
    }

    public func shouldSnapshot(rowIndex: Int) -> Bool {
        guard let snapshotEveryNRows else {
            return false
        }
        return rowIndex == 0 || (rowIndex + 1) % snapshotEveryNRows == 0
    }

    public func shouldClearCache(rowIndex: Int) -> Bool {
        guard let clearCacheEveryNRows else {
            return false
        }
        return rowIndex == 0 || (rowIndex + 1) % clearCacheEveryNRows == 0
    }
}
