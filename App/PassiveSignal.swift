import Cocoa
import CoreAudio
import IOKit.pwr_mgt

/// 被动使用信号：前台 App 正在保持屏幕常亮，或（网页时）浏览器正在出声。
/// 只作正向证据：任何一步读取失败都返回 false（宁可漏记，不凭空加分）。
enum PassiveSignal {

    /// bundleId 所属进程当前是否存在合格信号。
    /// includeAudio=true 时才把音频输出计入（原生 App 的音频不算，防后台音乐误伤）。
    static func isActive(bundleId: String, includeAudio: Bool) -> Bool {
        if displayAssertionActive(bundleId: bundleId) { return true }
        if includeAudio, audioOutputActive(bundleId: bundleId) { return true }
        return false
    }

    // MARK: - 保持屏幕常亮（电源断言）

    private static let displayAssertionTypes: Set<String> = [
        "NoDisplaySleepAssertion", "PreventUserIdleDisplaySleep"
    ]

    private static func displayAssertionActive(bundleId: String) -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dictionary = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return false
        }
        for (processID, assertions) in dictionary {
            let owns = assertions.contains { assertion in
                guard let type = assertion["AssertType"] as? String,
                      displayAssertionTypes.contains(type) else { return false }
                return (assertion["AssertLevel"] as? NSNumber)?.intValue ?? 0 > 0
            }
            if owns && ownerMatches(pid: processID.int32Value, bundleId: bundleId) { return true }
        }
        return false
    }

    // MARK: - 浏览器音频输出（Core Audio 进程对象，macOS 14.2+）

    private static func audioOutputActive(bundleId: String) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        var listAddress = audioAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &listAddress, 0, nil, &size) == noErr else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &listAddress, 0, nil, &size, &objects) == noErr else { return false }
        for object in objects {
            guard audioFlag(object, kAudioProcessPropertyIsRunningOutput),
                  let pid = audioInt32(object, kAudioProcessPropertyPID),
                  ownerMatches(pid: pid, bundleId: bundleId) else { continue }
            return true
        }
        return false
    }

    private static func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioFlag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = audioAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func audioInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t? {
        var address = audioAddress(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.stride)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - 归属判定

    /// 断言/音频对象的属主判定：进程自身的 bundle 命中，或其责任进程（responsibility）的 bundle 命中。
    private static func ownerMatches(pid: pid_t, bundleId: String) -> Bool {
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleId { return true }
        guard let responsible = responsiblePID(of: pid), responsible != pid else { return false }
        return NSRunningApplication(processIdentifier: responsible)?.bundleIdentifier == bundleId
    }

    /// 注意：返回值本身即责任 pid（out 参数不落值），失败返回 -1。查不到符号时退回进程自身。
    private typealias ResponsibilityFunction = @convention(c) (pid_t, UnsafeMutablePointer<pid_t>) -> Int32
    private static let responsibilityLookup: ResponsibilityFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    private static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let lookup = responsibilityLookup else { return nil }
        var out: pid_t = 0
        let result = lookup(pid, &out)
        let resolved = out != 0 ? out : result
        return resolved > 0 ? resolved : nil
    }
}
