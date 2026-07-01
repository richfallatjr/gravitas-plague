import Foundation

public enum TuringQwenNativePerformanceMode: String, Sendable, Equatable {
    case diagnostic
    case performance

    var runtimeOptions: TuringQwenNativeRuntimeOptions {
        switch self {
        case .diagnostic:
            return .diagnostic
        case .performance:
            return .performance
        }
    }

    var shouldForceEveryEval: Bool {
        runtimeOptions.enableForcedIntermediateEval
    }

    var shouldClearMLXCacheEveryRow: Bool {
        runtimeOptions.enablePerRowCacheClear
    }

    var shouldWriteRowBudgetEveryRow: Bool {
        runtimeOptions.enableDiskRowBudgetWrites
    }

    var shouldLogFullTokenRows: Bool {
        runtimeOptions.enablePerTokenLogs
    }

    var shouldLogMemorySnapshots: Bool {
        runtimeOptions.enablePerLayerMemorySnapshots
    }

    var shouldUsePreciseAttentionSoftmax: Bool {
        runtimeOptions.enablePreciseAttentionSoftmax
    }

    var shouldUseFastGroupedQueryAttention: Bool {
        runtimeOptions.enableFastGroupedQueryAttention
    }

    var rowCheckpointStride: Int {
        runtimeOptions.rowCheckpointInterval
    }

    var mlxCacheLimitBytes: Int {
        runtimeOptions.mlxCacheLimitBytes
    }
}

public enum TuringQwenNativeSamplerMode: String, Sendable {
    case greedy
    case temperatureTopP
}

public struct TuringQwenNativeRuntimeOptions: Sendable, Equatable {
    public let mode: TuringQwenNativePerformanceMode
    public let rowCheckpointInterval: Int
    public let enablePerLayerMemorySnapshots: Bool
    public let enablePerTokenLogs: Bool
    public let enableDiskRowBudgetWrites: Bool
    public let enableForcedIntermediateEval: Bool
    public let enablePerRowCacheClear: Bool
    public let enablePreciseAttentionSoftmax: Bool
    public let enableFastGroupedQueryAttention: Bool
    public let mlxCacheLimitBytes: Int

    public static let performance = TuringQwenNativeRuntimeOptions(
        mode: .performance,
        rowCheckpointInterval: 8,
        enablePerLayerMemorySnapshots: false,
        enablePerTokenLogs: false,
        enableDiskRowBudgetWrites: false,
        enableForcedIntermediateEval: false,
        enablePerRowCacheClear: false,
        enablePreciseAttentionSoftmax: false,
        enableFastGroupedQueryAttention: true,
        mlxCacheLimitBytes: 512 * 1024 * 1024
    )

    public static let diagnostic = TuringQwenNativeRuntimeOptions(
        mode: .diagnostic,
        rowCheckpointInterval: 1,
        enablePerLayerMemorySnapshots: true,
        enablePerTokenLogs: true,
        enableDiskRowBudgetWrites: true,
        enableForcedIntermediateEval: true,
        enablePerRowCacheClear: true,
        enablePreciseAttentionSoftmax: true,
        enableFastGroupedQueryAttention: false,
        mlxCacheLimitBytes: 64 * 1024 * 1024
    )
}
