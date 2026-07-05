import Darwin.Mach
import Foundation

struct TuringQwenNativeProcessMemorySnapshot: Sendable {
    let physFootprintMB: Double
    let residentSizeMB: Double
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
                residentSizeMB: 0
            )
        }

        let divisor = 1024.0 * 1024.0
        return TuringQwenNativeProcessMemorySnapshot(
            physFootprintMB: Double(info.phys_footprint) / divisor,
            residentSizeMB: Double(info.resident_size) / divisor
        )
    }
}
