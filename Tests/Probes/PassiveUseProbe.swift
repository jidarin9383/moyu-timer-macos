import Cocoa
import CoreAudio
import IOKit.pwr_mgt

@main
struct PassiveUseProbe {
    static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let workspace = NSWorkspace.shared
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let arguments = CommandLine.arguments
        func option(_ key: String, fallback: String) -> String {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return fallback }
            return arguments[index + 1]
        }
        if let eventsIndex = arguments.firstIndex(of: "--events"), eventsIndex + 1 < arguments.count {
            runEventMode(seconds: max(0.1, Double(arguments[eventsIndex + 1]) ?? 10))
            return
        }
        let label = option("--label", fallback: "snapshot")
        let count = max(1, Int(option("--samples", fallback: "1")) ?? 1)
        let interval = max(0.1, Double(option("--interval", fallback: "1")) ?? 1)
        for sample in 0..<count {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            var raw: Unmanaged<CFDictionary>?
            let result = IOPMCopyAssertionsByProcess(&raw)
            let front = workspace.frontmostApplication
            var output: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "label": label,
                "sample": sample,
                "returnCode": result,
                "frontmostPID": front?.processIdentifier ?? 0,
                "frontmostBundle": front?.bundleIdentifier ?? "unknown"
            ]
            var rows: [[String: Any]] = []
            if result == kIOReturnSuccess, let dictionary = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] {
                for (processID, assertions) in dictionary {
                    for assertion in assertions {
                        let type = assertion["AssertType"] as? String ?? "unknown"
                        guard type.lowercased().contains("sleep") else { continue }
                        let application = NSRunningApplication(processIdentifier: processID.int32Value)
                        var row: [String: Any] = [
                            "pid": processID,
                            "bundle": application?.bundleIdentifier ?? "unknown",
                            "executable": application?.executableURL?.lastPathComponent ?? "unknown",
                            "type": type,
                            "level": assertion["AssertLevel"] as? NSNumber ?? 0,
                            "id": assertion["AssertionId"] as? NSNumber ?? 0
                        ]
                        let name = (assertion["AssertName"] as? String ?? "").lowercased()
                        row["nameHints"] = ["video", "audio", "wake lock", "display"].filter { name.contains($0) }
                        row["associatedPIDs"] = assertion.reduce(into: [String: NSNumber]()) { values, pair in
                            if pair.key.lowercased().contains("pid"), let number = pair.value as? NSNumber {
                                values[pair.key] = number
                            }
                        }
                        rows.append(row)
                    }
                }
                output["readSucceeded"] = true
            } else {
                output["readSucceeded"] = false
            }
            output["assertions"] = rows.sorted { ($0["pid"] as? NSNumber)?.intValue ?? 0 < ($1["pid"] as? NSNumber)?.intValue ?? 0 }
            let audio = audioProcessRows()
            output["audio"] = audio.rows
            output["audioReadSucceeded"] = audio.succeeded
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            output["onScreenWindowOwnerPIDs"] = windows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
                .prefix(4).compactMap { $0[kCGWindowOwnerPID as String] as? Int }
            output["readDurationMs"] = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if sample + 1 < count { RunLoop.main.run(until: Date().addingTimeInterval(interval)) }
        }
    }

    static func runEventMode(seconds: Double) {
        let formatter = ISO8601DateFormatter()
        func emit(_ event: String) {
            let payload: [String: Any] = [
                "timestamp": formatter.string(from: Date()),
                "event": event,
                "hidIdleSeconds": hidIdleSeconds()
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
        var observers: [NSObjectProtocol] = []
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "willSleep"),
            (NSWorkspace.didWakeNotification, "didWake"),
            (NSWorkspace.screensDidSleepNotification, "screensDidSleep"),
            (NSWorkspace.screensDidWakeNotification, "screensDidWake")
        ]
        for (name, event) in workspaceEvents {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { _ in emit(event) })
        }
        let distributedCenter = DistributedNotificationCenter.default()
        let distributedEvents = [
            "com.apple.screenIsLocked",
            "com.apple.screenIsUnlocked",
            "com.apple.screensaver.didstart",
            "com.apple.screensaver.willstop",
            "com.apple.screensaver.didstop"
        ]
        for name in distributedEvents {
            observers.append(distributedCenter.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in emit(name) })
        }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        for observer in observers {
            workspaceCenter.removeObserver(observer)
            distributedCenter.removeObserver(observer)
        }
    }

    static func hidIdleSeconds() -> Double {
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
              let nanos = dict["HIDIdleTime"] as? UInt64 else {
            return 0
        }
        return Double(nanos) / 1_000_000_000
    }

    static func parentPID(of pid: Int32) -> Int? {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected else { return nil }
        return Int(info.pbi_ppid)
    }

    static func audioPropertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func audioInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var address = audioPropertyAddress(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.stride)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func audioUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = audioPropertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func audioString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = audioPropertyAddress(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    static func audioProcessRows() -> (rows: [[String: Any]], succeeded: Bool) {
        guard #available(macOS 14.2, *) else { return ([], false) }
        var listAddress = audioPropertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size)
        guard status == noErr else { return ([], false) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var objects = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &objects)
        guard status == noErr else { return ([], false) }
        let browserPrefixes = ["com.google.Chrome", "com.apple.Safari", "com.apple.WebKit"]
        var rows: [[String: Any]] = []
        for object in objects {
            let pid = audioInt32(object, kAudioProcessPropertyPID) ?? -1
            let bundle = audioString(object, kAudioProcessPropertyBundleID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            let runningOutput = (audioUInt32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            let runningInput = (audioUInt32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
            let browserOwned = bundle.map { name in browserPrefixes.contains { name.hasPrefix($0) } } ?? false
            guard runningOutput || runningInput || browserOwned else { continue }
            var row: [String: Any] = [
                "pid": NSNumber(value: pid),
                "ppid": parentPID(of: pid).map { NSNumber(value: $0) } ?? NSNull(),
                "bundle": bundle ?? NSNull(),
                "isRunningOutput": runningOutput,
                "isRunningInput": runningInput
            ]
            if let symbol = dlsym(ResponsibilityLookup.handle, "responsibility_get_pid_responsible_for_pid") {
                typealias ResponsibilityFunction = @convention(c) (pid_t, UnsafeMutablePointer<pid_t>) -> Int32
                let function = unsafeBitCast(symbol, to: ResponsibilityFunction.self)
                var responsible: pid_t = 0
                let result = function(pid, &responsible)
                let resolved = responsible != 0 ? responsible : result
                if resolved > 0 {
                    row["responsiblePID"] = NSNumber(value: resolved)
                    row["responsibleBundle"] = NSRunningApplication(processIdentifier: resolved)?.bundleIdentifier ?? NSNull()
                } else {
                    row["responsiblePID"] = NSNull()
                    row["responsibleBundle"] = NSNull()
                }
            } else {
                row["responsiblePID"] = NSNull()
                row["responsibleBundle"] = NSNull()
            }
            rows.append(row)
        }
        return (rows.sorted { ($0["pid"] as? NSNumber)?.intValue ?? 0 < ($1["pid"] as? NSNumber)?.intValue ?? 0 }, true)
    }

    enum ResponsibilityLookup {
        static let handle = dlopen(nil, RTLD_LAZY)
    }
}
