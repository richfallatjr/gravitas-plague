import Darwin.Mach
import Foundation

struct TuringMemorySnapshot: Codable, Sendable, Hashable {
    let label: String
    let segmentIndex: Int
    let residentSizeBytes: UInt64
    let physFootprintBytes: UInt64
    let timestamp: Date
}

actor TuringMemoryFootprintProbe {
    func snapshot(
        label: String,
        segmentIndex: Int
    ) -> TuringMemorySnapshot {
        let values = Self.currentTaskVMInfo()
        let snapshot = TuringMemorySnapshot(
            label: label,
            segmentIndex: segmentIndex,
            residentSizeBytes: values.residentSizeBytes,
            physFootprintBytes: values.physFootprintBytes,
            timestamp: Date()
        )

        print(
            """
            [TuringMemory] snapshot
              label: \(label)
              segmentIndex: \(segmentIndex)
              residentSizeBytes: \(snapshot.residentSizeBytes)
              physFootprintBytes: \(snapshot.physFootprintBytes)
            """
        )

        return snapshot
    }

    private static func currentTaskVMInfo() -> (
        residentSizeBytes: UInt64,
        physFootprintBytes: UInt64
    ) {
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
            return (0, 0)
        }

        return (
            residentSizeBytes: UInt64(info.resident_size),
            physFootprintBytes: UInt64(info.phys_footprint)
        )
    }
}
