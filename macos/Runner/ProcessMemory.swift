import Darwin
import Foundation

/// Current process memory (Activity Monitor–style footprint).
enum ProcessMemory {
  /// phys_footprint + resident for the Singlet UI process.
  static func appSnapshot() -> [String: Any] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
    )
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
      }
    }
    guard kr == KERN_SUCCESS else {
      return ["ok": false]
    }
    return [
      "ok": true,
      "footprint": Int(info.phys_footprint),
      "resident": Int(info.resident_size),
    ]
  }
}
