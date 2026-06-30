import Foundation

public enum TuringQwenNativePerformanceMode: String, Sendable, Equatable {
    case diagnostic
    case performance

    var shouldForceEveryEval: Bool {
        self == .diagnostic
    }

    var shouldClearMLXCacheEveryRow: Bool {
        self == .diagnostic
    }

    var shouldWriteRowBudgetEveryRow: Bool {
        self == .diagnostic
    }

    var shouldLogFullTokenRows: Bool {
        self == .diagnostic
    }

    var rowCheckpointStride: Int {
        switch self {
        case .diagnostic:
            return 1
        case .performance:
            return 5
        }
    }
}

public enum TuringQwenNativeSamplerMode: String, Sendable {
    case greedy
    case temperatureTopP
}
