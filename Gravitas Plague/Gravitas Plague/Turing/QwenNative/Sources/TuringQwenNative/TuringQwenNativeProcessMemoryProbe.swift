import Darwin
import Foundation

struct TuringQwenNativeProcessMemorySnapshot: Sendable {
    let physFootprintMB: Double
    let residentSizeMB: Double
    let availableProcessMemoryMB: Double
}

enum TuringQwenNativeProcessMemoryProbe {
    static func snapshot() -> TuringQwenNativeProcessMemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size /
            MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return TuringQwenNativeProcessMemorySnapshot(
                physFootprintMB: 0,
                residentSizeMB: 0,
                availableProcessMemoryMB: availableProcessMemoryMB()
            )
        }

        let divisor = 1024.0 * 1024.0
        return TuringQwenNativeProcessMemorySnapshot(
            physFootprintMB: Double(info.phys_footprint) / divisor,
            residentSizeMB: Double(info.resident_size) / divisor,
            availableProcessMemoryMB: availableProcessMemoryMB()
        )
    }

    private static func availableProcessMemoryMB() -> Double {
        #if os(visionOS) || os(iOS) || os(tvOS)
        return Double(max(os_proc_available_memory(), 0)) / 1_048_576.0
        #else
        return 0
        #endif
    }
}
