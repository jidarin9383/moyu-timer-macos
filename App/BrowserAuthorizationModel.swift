import Combine

/// One authorization entry, backed by the supported browsers that are actually running.
/// Refreshing is silent. Only performAction may request consent or open System Settings.
final class BrowserAuthorizationModel: ObservableObject {
    @Published private(set) var status = "打开浏览器后可授权"
    @Published private(set) var canAct = false
    @Published private(set) var needsAuthorization = true
    @Published private(set) var isChecking = false
    private let runningBrowsers: () -> [String]
    private let check: ([String], @escaping ([String: BrowserPermissionResult]) -> Void) -> Void
    private let request: (String) -> Void
    private let manage: () -> Void
    private var revision = 0
    private var actionRequested = false

    init(runningBrowsers: @escaping () -> [String],
         check: @escaping ([String], @escaping ([String: BrowserPermissionResult]) -> Void) -> Void,
         request: @escaping (String) -> Void, manage: @escaping () -> Void) {
        self.runningBrowsers = runningBrowsers
        self.check = check
        self.request = request
        self.manage = manage
    }

    private var liveBrowsers: [String] {
        Array(Set(runningBrowsers().filter { WebGroup.supportsURLReading($0) })).sorted()
    }

    func refresh() {
        revision += 1
        let currentRevision = revision
        let browsers = liveBrowsers
        canAct = !browsers.isEmpty
        guard !browsers.isEmpty else {
            status = "打开浏览器后可授权"
            needsAuthorization = true
            isChecking = false
            actionRequested = false
            return
        }
        isChecking = true
        check(browsers) { [weak self] results in
            guard let self, self.revision == currentRevision else { return }
            guard self.liveBrowsers == browsers else { self.refresh(); return }
            let pending = browsers.filter { if case .authorized = results[$0] { return false }; return true }
            self.needsAuthorization = !pending.isEmpty
            self.status = pending.isEmpty ? "已授权 \(browsers.count) 个运行中的浏览器" : "待授权 \(pending.count) 个浏览器"
            self.isChecking = false
            guard self.actionRequested else { return }
            self.actionRequested = false
            if let target = pending.first { self.request(target) } else { self.manage() }
        }
    }

    func performAction() {
        guard !actionRequested else { return }
        actionRequested = true
        refresh()
    }
}
