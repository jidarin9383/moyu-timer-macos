import SwiftUI
import ServiceManagement

/// Compact native preferences, with one entry for live browser consent.
struct SettingsView: View {
    let store: Store
    @ObservedObject var tracker: UsageTracker
    var checksBrowserPermission = true
    @State private var launchAtLogin: Bool
    @State private var idleMinutes: Int
    @State private var loginError: String?
    @StateObject private var browserAuthorization: BrowserAuthorizationModel
    @AppStorage(MenuBarStyle.preferenceKey) private var menuBarStyle = MenuBarStyle.rate.rawValue
    @AppStorage(UsageTracker.webRetryPendingKey) private var webPermissionPending = false
    @AppStorage(UsageTracker.webPermissionMessageKey) private var webPermissionMessage = ""

    init(store: Store, tracker: UsageTracker, checksBrowserPermission: Bool = true) {
        self.store = store; self.tracker = tracker; self.checksBrowserPermission = checksBrowserPermission
        _browserAuthorization = StateObject(wrappedValue: BrowserAuthorizationModel(
            runningBrowsers: checksBrowserPermission ? tracker.runningBrowsersProvider : { [] },
            check: BrowserURLReader.checkAuthorization,
            request: { tracker.goAuthorize(bundleId: $0) },
            manage: { tracker.openBrowserPermissionSettings() }))
        _launchAtLogin = State(initialValue: checksBrowserPermission && SMAppService.mainApp.status == .enabled)
        _idleMinutes = State(initialValue: min(15, max(0, UserDefaults.standard.object(forKey: "idleThresholdMinutes") as? Int ?? 5)))
    }
    private var loginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: { value in
            do {
                if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLogin = SMAppService.mainApp.status == .enabled; loginError = nil
            } catch {
                loginError = "请先将应用放入 Applications 文件夹后重试。"
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        })
    }
    private func refreshPermission() {
        guard checksBrowserPermission else { return }
        browserAuthorization.refresh()
    }
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
    private var feedbackURL: URL {
        var parts = URLComponents(); parts.scheme = "mailto"; parts.path = "jidarin9383@gmail.com"
        parts.queryItems = [URLQueryItem(name: "subject", value: "摸了个鱼反馈 v\(appVersion)")]
        return parts.url!
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("记录与判定") {
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("开机自动启动").foregroundStyle(AquariumStyle.ink)
                                Text("系统登录后自动在菜单栏静默运行").font(.system(size: 10)).foregroundStyle(AquariumStyle.muted)
                            }
                            Spacer()
                            Toggle("开机自动启动", isOn: loginBinding).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }.padding(10)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("闲置判定时长")
                                Text(idleMinutes == 0 ? "关闭闲置判定，锁屏和暂停仍不计时" : "无键盘鼠标操作后暂停计时")
                                    .font(.system(size: 10)).foregroundStyle(AquariumStyle.muted)
                            }
                            Spacer(minLength: 0)
                            Slider(value: Binding(get: { Double(idleMinutes) }, set: {
                                idleMinutes = Int($0); UserDefaults.standard.set(idleMinutes, forKey: "idleThresholdMinutes")
                            }), in: 0...15, step: 1)
                            .frame(width: 104).accessibilityLabel("闲置判定分钟数")
                            Text(idleMinutes == 0 ? "关闭" : "\(idleMinutes) 分钟").font(.system(size: 10)).monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }.padding(10)
                    }
                }
                if let loginError { Text(loginError).font(.system(size: 10)).foregroundStyle(AquariumStyle.leisureText) }
                section("浏览器追踪授权") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("网站统计权限")
                            Spacer()
                            Text(webPermissionPending ? "授权中…" : browserAuthorization.status)
                                .font(.system(size: 10))
                                .foregroundStyle(browserAuthorization.needsAuthorization ? AquariumStyle.muted : AquariumStyle.workText)
                            if browserAuthorization.canAct {
                                Button(browserAuthorization.needsAuthorization ? "授权" : "管理") {
                                    browserAuthorization.performAction()
                                }
                                .buttonStyle(.borderless).controlSize(.small)
                                .disabled(webPermissionPending || browserAuthorization.isChecking)
                            }
                        }
                        Text(webPermissionMessage.isEmpty
                             ? "Firefox 使用辅助功能权限，其他浏览器使用自动化权限；仅读取当前网页地址。"
                             : webPermissionMessage)
                            .font(.system(size: 9.5)).foregroundStyle(AquariumStyle.muted)
                    }.padding(10)
                }
                section("菜单栏显示形态") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                        ForEach(MenuBarStyle.allCases, id: \.rawValue) { style in
                            let selected = menuBarStyle == style.rawValue
                            Button { menuBarStyle = style.rawValue } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(selected ? AquariumStyle.work : AquariumStyle.border).frame(width: 7, height: 7)
                                    Text(style == .plain ? "小鱼图标" : style.rawValue)
                                        .fontWeight(selected ? .semibold : .regular)
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(selected ? AquariumStyle.workText : AquariumStyle.ink)
                                .padding(.horizontal, 8).padding(.vertical, 7)
                                .background(selected ? AquariumStyle.habitatTop : AquariumStyle.background,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(selected ? AquariumStyle.work : AquariumStyle.border, lineWidth: 1))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain).accessibilityLabel(style.rawValue)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }.padding(10)
                }
                section("本地存储与隐私") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("数据存储路径")
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([store.databaseURL]) } label: {
                                Text("在访达中显示")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(AquariumStyle.ink)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(AquariumStyle.background, in: RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AquariumStyle.border, lineWidth: 1))
                                    .contentShape(RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain)
                        }
                        Text((store.databaseURL.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(AquariumStyle.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(AquariumStyle.background, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(AquariumStyle.border, lineWidth: 0.6))
                        Label("使用记录仅保存在这台 Mac，不上传；网站只保存域名。", systemImage: "checkmark.shield")
                            .font(.system(size: 10)).foregroundStyle(AquariumStyle.workText)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(10)
                }
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("关于摸了个鱼").font(.system(size: 12, weight: .semibold)).foregroundStyle(AquariumStyle.ink)
                            Spacer()
                            Text("v\(appVersion)")
                        }
                        Text("记录这台 Mac 的前台使用时间，按工作和摸鱼分类。")
                        Divider()
                        HStack {
                            Text("反馈问题").foregroundStyle(AquariumStyle.ink)
                            Spacer()
                            Link("jidarin9383@gmail.com", destination: feedbackURL)
                        }
                    }.foregroundStyle(AquariumStyle.muted).padding(12)
                }
                HStack(spacing: 0) {
                    Text("❤️Lovely made by ").foregroundStyle(AquariumStyle.muted)
                    Link(destination: URL(string: "https://www.xiaohongshu.com/user/profile/5d8b6f76000000000101b44c")!) {
                        HStack(spacing: 2) {
                            Text("戴伦")
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                        }
                    }
                }.font(.system(size: 10.5)).frame(maxWidth: .infinity).padding(.top, 2)
            }.padding(18)
        }
        .frame(width: 440, height: 400).background(AquariumStyle.background)
        .font(.system(size: 11)).foregroundStyle(AquariumStyle.ink).tint(AquariumStyle.work)
        .onAppear(perform: refreshPermission)
        .onChange(of: webPermissionPending) { pending in if !pending { refreshPermission() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermission() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshPermission() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshPermission() }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(AquariumStyle.muted)
            card(content: content)
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().background(AquariumStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AquariumStyle.border, lineWidth: 0.6))
    }
}
