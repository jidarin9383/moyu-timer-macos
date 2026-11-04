import Cocoa
import Carbon

enum URLQueryResult {
    case domain(String)
    case videoPage(String)
    case denied
    case failed
    case pending
}

enum BrowserPermissionResult {
    case authorized
    case denied
    case failed
}

/// Browser queries are serialized off the UI thread. Only an explicit user action
/// may present the system consent prompt; routine URL reads never prompt.
enum BrowserURLReader {
    static let permissionDeniedKey = "webURLPermissionDenied"
    private static let queryQueue = DispatchQueue(label: "com.darinji.moyutimer.browserURL", qos: .utility)
    private static let permissionQueue = DispatchQueue(label: "com.darinji.moyutimer.browserPermission", qos: .userInitiated)
    private static var inFlight = false

    /// Read current consent without opening a browser or presenting a system prompt.
    static func checkAuthorization(bundleIds: [String], completion: @escaping ([String: BrowserPermissionResult]) -> Void) {
        permissionQueue.async {
            var results: [String: BrowserPermissionResult] = [:]
            for bundle in bundleIds where WebGroup.supportsURLReading(bundle) {
                if WebGroup.usesAccessibility(bundle) {
                    results[bundle] = FirefoxURLReader.isAuthorized ? .authorized : .denied
                    continue
                }
                let status = permissionStatus(bundleId: bundle, askUser: false)
                results[bundle] = status == noErr ? .authorized
                    : (status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent ? .denied : .failed)
            }
            DispatchQueue.main.async { completion(results) }
        }
    }

    static func requestAuthorization(bundleId: String,
                                     completion: @escaping (BrowserPermissionResult) -> Void) {
        guard WebGroup.supportsURLReading(bundleId) else {
            completion(.failed)
            return
        }
        if WebGroup.usesAccessibility(bundleId) {
            DispatchQueue.main.async { completion(FirefoxURLReader.requestAuthorization()) }
            return
        }
        permissionQueue.async {
            let status = permissionStatus(bundleId: bundleId, askUser: true)
            let result: BrowserPermissionResult = status == noErr ? .authorized
                : (status == errAEEventNotPermitted ? .denied : .failed)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func currentDomain(bundleId: String, completion: @escaping (URLQueryResult) -> Void) {
        guard !inFlight else { completion(.pending); return }
        guard WebGroup.supportsURLReading(bundleId) else {
            completion(.failed)
            return
        }
        inFlight = true
        queryQueue.async {
            let result = WebGroup.usesAccessibility(bundleId)
                ? FirefoxURLReader.currentDomain(bundleId: bundleId) : queryDomain(bundleId: bundleId)
            DispatchQueue.main.async {
                inFlight = false
                completion(result)
            }
        }
    }

    private static func permissionStatus(bundleId: String, askUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, askUser)
    }

    private static func queryDomain(bundleId: String) -> URLQueryResult {
        let status = permissionStatus(bundleId: bundleId, askUser: false)
        if status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent {
            return .denied
        }
        guard status == noErr else { return .failed }
        guard let property = WebGroup.urlQueryProperty(bundleId) else { return .failed }
        // An unresponsive browser must release the serial reader so another browser can be queried.
        let source = """
            with timeout of 2 seconds
                tell application id "\(bundleId)" to get \(property)
            end timeout
            """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
            return code == errAEEventNotPermitted ? .denied : .failed
        }
        guard let text = result.stringValue else { return .failed }
        return classifyURL(text)
    }

    static func classifyURL(_ text: String) -> URLQueryResult {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let domain = normalizeDomain(text) else { return .failed }
        return VideoPageRules.matches(url) ? .videoPage(domain) : .domain(domain)
    }

    static func normalizeDomain(_ urlString: String) -> String? {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s), let host = comps.host else { return nil }
        var domain = host.lowercased()
        if domain.hasPrefix("www.") { domain = String(domain.dropFirst(4)) }
        return domain.isEmpty ? nil : domain
    }
}
