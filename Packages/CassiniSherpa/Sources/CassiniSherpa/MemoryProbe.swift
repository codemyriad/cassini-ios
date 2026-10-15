import Foundation
import Darwin
#if canImport(os)
import os
#endif

/// The process's memory as jetsam counts it: `phys_footprint` now and its peak since launch, and what
/// `os_proc_available_memory()` says is left (0 where there is no limit, such as the simulator).
public struct MemorySample: Sendable, Equatable {
    public let footprintBytes: UInt64
    public let peakFootprintBytes: UInt64
    public let availableBytes: UInt64

    public static func now() -> MemorySample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return MemorySample(footprintBytes: 0, peakFootprintBytes: 0, availableBytes: 0) }
        #if os(iOS)
        let available = UInt64(os_proc_available_memory())
        #else
        let available: UInt64 = 0
        #endif
        return MemorySample(footprintBytes: info.phys_footprint, peakFootprintBytes: UInt64(info.ledger_phys_footprint_peak),
                            availableBytes: available)
    }
}
