import Cocoa
import ApplicationServices

/// Reads only the focused Firefox window's committed document URL.
/// Toolbars and page descendants are skipped: typed searches, iframe URLs and body text are never read.
enum FirefoxURLReader {
    static var isAuthorized: Bool { AXIsProcessTrusted() }

    /// Explicit user action only. macOS requires the user to enable the app in Accessibility settings.
    static func requestAuthorization() -> BrowserPermissionResult {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .authorized : .denied
    }

    /// Never combine multiple top-level documents or fall back to an editable address field.
    static func selectedURL(windowDocument: String?, webAreaURLs: [String?]) -> String? {
        if let windowDocument, !windowDocument.isEmpty { return httpURL(windowDocument) }
        guard webAreaURLs.count == 1, let value = webAreaURLs[0] else { return nil }
        return httpURL(value)
    }

    private static func httpURL(_ value: String) -> String? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        return value
    }

    static func currentDomain(bundleId: String) -> URLQueryResult {
        guard WebGroup.usesAccessibility(bundleId) else { return .failed }
        guard isAuthorized else { return .denied }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleId else { return .failed }
        let pid = front.processIdentifier
        guard let value = focusedDocumentURL(for: front),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .failed }
        return BrowserURLReader.classifyURL(value)
    }

    /// Kept separate for read-only integration probes. Production calls this only for the foreground process.
    static func focusedDocumentURL(for process: NSRunningApplication) -> String? {
        guard process.bundleIdentifier == "org.mozilla.firefox", isAuthorized else { return nil }
        let application = AXUIElementCreateApplication(process.processIdentifier)
        guard AXUIElementSetMessagingTimeout(application, 0.08) == .success,
              let focused = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(focused, to: AXUIElement.self)
        let document = urlString(attribute(window, kAXDocumentAttribute))
        var webAreas: [String?] = []
        var remaining = 192
        var complete = true
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        let skippedRoles: Set<String> = ["AXToolbar", "AXMenuBar", "AXMenu", "AXSheet", "AXDialog"]
        func visit(_ element: AXUIElement, depth: Int) {
            guard remaining > 0, depth <= 10, ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false; return
            }
            remaining -= 1
            guard let role = attribute(element, kAXRoleAttribute) as? String else { complete = false; return }
            if skippedRoles.contains(role) { return }
            if role == "AXWebArea" {
                webAreas.append(urlString(attribute(element, kAXURLAttribute)))
                return
            }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                visit(child, depth: depth + 1)
                if !complete || webAreas.count > 1 { break }
            }
        }
        if document == nil || document?.isEmpty == true { visit(window, depth: 0) }
        guard complete else { return nil }
        return selectedURL(windowDocument: document, webAreaURLs: webAreas)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func urlString(_ value: CFTypeRef?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }
}
