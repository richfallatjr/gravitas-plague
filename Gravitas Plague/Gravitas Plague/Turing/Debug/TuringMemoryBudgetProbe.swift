import Darwin
import Foundation
import TuringQwenNative

struct TuringMemoryBudgetSnapshot: Codable, Sendable {
    let label: String
    let availableProcessMemoryBytes: UInt64
    let physicalFootprintBytes: UInt64
    let residentSizeBytes: UInt64
    let mlxActiveMemoryBytes: Int
    let mlxCacheMemoryBytes: Int
    let mlxPeakMemoryBytes: Int
    let mlxCacheLimitBytes: Int
    let mlxMemoryLimitBytes: Int
    let activeQwenModelID: String?
    let quantization: String?
    let increasedMemoryEntitlementStatus: String

    var availableProcessMemoryMB: UInt64 {
        availableProcessMemoryBytes / 1_048_576
    }

    var physicalFootprintMB: UInt64 {
        physicalFootprintBytes / 1_048_576
    }

    var residentSizeMB: UInt64 {
        residentSizeBytes / 1_048_576
    }

    var mlxActiveMemoryMB: Int {
        mlxActiveMemoryBytes / 1_048_576
    }

    var mlxCacheMemoryMB: Int {
        mlxCacheMemoryBytes / 1_048_576
    }

    var mlxPeakMemoryMB: Int {
        mlxPeakMemoryBytes / 1_048_576
    }
}

enum TuringMemoryBudgetProbe {
    private static let entitlementStatus = "requested_in_entitlements"

    @discardableResult
    static func log(
        label: String,
        activeQwenModelID: String? = nil,
        quantization: String? = nil,
        runID: String? = nil,
        segmentIndex: Int? = nil,
        details: [String: String] = [:]
    ) -> TuringMemoryBudgetSnapshot {
        let snapshot = currentSnapshot(
            label: label,
            activeQwenModelID: activeQwenModelID,
            quantization: quantization
        )

        print("""
        [TuringMemory] budget snapshot
          label: \(snapshot.label)
          os_proc_available_memory_MB: \(snapshot.availableProcessMemoryMB)
          phys_footprint_MB: \(snapshot.physicalFootprintMB)
          resident_size_MB: \(snapshot.residentSizeMB)
          mlx_active_MB: \(snapshot.mlxActiveMemoryMB)
          mlx_cache_MB: \(snapshot.mlxCacheMemoryMB)
          mlx_peak_MB: \(snapshot.mlxPeakMemoryMB)
          mlx_cache_limit_MB: \(snapshot.mlxCacheLimitBytes / 1_048_576)
          mlx_memory_limit_MB: \(snapshot.mlxMemoryLimitBytes / 1_048_576)
          activeQwenModelID: \(snapshot.activeQwenModelID ?? "none")
          quantization: \(snapshot.quantization ?? "none")
          increasedMemoryEntitlement: \(snapshot.increasedMemoryEntitlementStatus)
        """)

        TuringProductionDiagnostics.recordMemory(
            snapshot,
            runID: runID,
            segmentIndex: segmentIndex,
            details: details
        )

        return snapshot
    }

    static func currentSnapshot(
        label: String,
        activeQwenModelID: String? = nil,
        quantization: String? = nil
    ) -> TuringMemoryBudgetSnapshot {
        let mlx = TuringQwenNativeDiagnostics.memorySnapshot()
        return TuringMemoryBudgetSnapshot(
            label: label,
            availableProcessMemoryBytes: availableProcessMemory(),
            physicalFootprintBytes: physicalFootprint(),
            residentSizeBytes: residentSize(),
            mlxActiveMemoryBytes: mlx.activeMemoryBytes,
            mlxCacheMemoryBytes: mlx.cacheMemoryBytes,
            mlxPeakMemoryBytes: mlx.peakMemoryBytes,
            mlxCacheLimitBytes: mlx.cacheLimitBytes,
            mlxMemoryLimitBytes: mlx.memoryLimitBytes,
            activeQwenModelID: activeQwenModelID,
            quantization: quantization,
            increasedMemoryEntitlementStatus: entitlementStatus
        )
    }

    private static func availableProcessMemory() -> UInt64 {
        #if os(visionOS) || os(iOS) || os(tvOS)
        return UInt64(max(os_proc_available_memory(), 0))
        #else
        return 0
        #endif
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size /
            MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        return UInt64(info.phys_footprint)
    }

    private static func residentSize() -> UInt64 {
        var info = task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_basic_info_data_t>.size /
            MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        return UInt64(info.resident_size)
    }
}
