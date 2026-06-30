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

    var rowCheckpointStride: Int {
        runtimeOptions.rowCheckpointInterval
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

    public static let performance = TuringQwenNativeRuntimeOptions(
        mode: .performance,
        rowCheckpointInterval: 8,
        enablePerLayerMemorySnapshots: false,
        enablePerTokenLogs: false,
        enableDiskRowBudgetWrites: false,
        enableForcedIntermediateEval: false,
        enablePerRowCacheClear: false
    )

    public static let diagnostic = TuringQwenNativeRuntimeOptions(
        mode: .diagnostic,
        rowCheckpointInterval: 1,
        enablePerLayerMemorySnapshots: true,
        enablePerTokenLogs: true,
        enableDiskRowBudgetWrites: true,
        enableForcedIntermediateEval: true,
        enablePerRowCacheClear: true
    )
}
