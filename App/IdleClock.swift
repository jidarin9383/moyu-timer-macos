import Foundation
import IOKit

/// 读取系统级键鼠空闲时间（秒）。不需要任何权限。
/// 读取失败时返回 0（按「活跃」处理：宁可多记，不可漏记）。
enum IdleClock {
    static func secondsSinceLastInput() -> TimeInterval {
        var iterator: io_iterator_t = 0
        defer { IOObjectRelease(iterator) }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        let service = IOIteratorNext(iterator)
        defer { IOObjectRelease(service) }
        guard service != 0 else { return 0 }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any],
              let idleNanos = dict["HIDIdleTime"] as? UInt64 else {
            return 0
        }
        return TimeInterval(idleNanos) / 1_000_000_000
    }
}
