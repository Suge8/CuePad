#if os(iOS)
import CueSync
import SwiftUI

/// 设置（项目页末尾、宽屏侧栏底部推入），按要紧排，分组与说法同 Mac 的设置窗口：Cue 一行（推入它的设置页，右边写它在哪台运行）；
/// iCloud 同步（状态、需要你决定时的两个选择或立即同步、两个版本的灵感或任务、没能同步的记录）；通知；外观；
/// 启动时没完成的事与上次崩溃有才出现；版本写在最底下。
struct SettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 宽屏上表单限宽居中，分段控件与说明不被拉成一长条（Cue 的设置页同宽）。
    static let readableWidth: CGFloat = 640

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Group {
                Section {
                    NavigationLink(value: Route.cueSettings) {
                        LabeledContent {
                            Text(workspace.cue.home ?? "")
                        } label: {
                            Label(workspace.cue.name, icon: .cue)
                        }
                    }
                }
                SyncSection()
                if services.sync != nil || Self.previewsAlerts { AlertSection() }
                Section {
                    Picker(selection: $settings.theme) {
                        Text("跟随系统").tag(AppSettings.Theme.system)
                        Text("浅色").tag(AppSettings.Theme.light)
                        Text("深色").tag(AppSettings.Theme.dark)
                    } label: {
                        Label("外观", icon: .appearance)
                    }
                }
                if !services.startupIssues.isEmpty {
                    Section("没能完成的事") {
                        ForEach(Array(services.startupIssues.enumerated()), id: \.offset) { _, issue in
                            Label { Text(issue.text) } icon: { FailureMark() }.font(.footnote)
                        }
                    }
                }
                if services.diagnostics.latest != nil { Section { LastCrashRow() } }
            }
            .listRowBackground(palette.paper)
            Section {} footer: {
                Text("CuePad \(AppServices.version)").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: sizeClass == .regular ? Self.readableWidth : .infinity)
        .frame(maxWidth: .infinity)
        .scrollContentBackground(.hidden)
        .floatingHeader("设置")
    }

    /// 演示模式没有同步：调试参数要看通知各状态时照样显示这一节。
    private static var previewsAlerts: Bool { DebugHooks.preset.alertStatus != nil }
}

/// 通知：一行状态（权限、推送注册、服务端订阅哪一步不通就写哪一步），能在这里解决的给按钮。
private struct AlertSection: View {
    @Environment(AppServices.self) private var services
    @Environment(AlertCenter.self) private var alerts
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    var body: some View {
        let live = PiAlertStatus(
            authorization: alerts.authorization, registration: alerts.registration, subscription: services.alertSubscription)
        let status = DebugHooks.preset.alertStatus ?? live
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                    if let detail = status.detail { Text(detail).font(.footnote).foregroundStyle(palette.ink3) }
                }
            } icon: {
                Image(status.state == .on ? .alertsOn : status.state == .pending ? .alertsPending : .alertsOff)
                    .foregroundStyle(status.state == .problem ? palette.failure : palette.ink2)
            }
            if let diagnostics = status.diagnostics {
                DisclosureGroup("详情") {
                    Text(diagnostics).font(.caption.monospaced()).foregroundStyle(palette.ink3).textSelection(.enabled)
                }
            }
            switch status.action {
            case .retry:
                Button("重试", icon: .retry) {
                    alerts.retryRegistration()
                    Task { await services.syncNow() }
                }
            case .openSettings:
                Button("打开系统通知设置", icon: .settings) {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            case .allow:
                Button("开启通知", icon: .alertsPending) { Task { await alerts.requestAuthorization() } }
            case nil:
                EmptyView()
            }
        } header: {
            Text("通知")
        }
    }
}

/// iCloud 同步：一行状态，需要决定时给出两个选择，否则是立即同步；有两个版本的灵感或任务时一行推入处理，没能同步的记录可展开。
private struct SyncSection: View {
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var confirmErase = false

    var body: some View {
        Section {
            let summary = SyncSummary(services.syncStatus)
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                    if let detail = summary.detail {
                        Text(detail).font(.footnote).foregroundStyle(palette.ink3)
                    }
                }
            } icon: {
                if services.isSyncBusy {
                    Spinner(.small)
                } else {
                    Image(summary.icon).foregroundStyle(palette.color(summary.tone))
                }
            }
            if services.sync != nil {
                if case .needsDecision = services.syncStatus {
                    Button("上传本机数据", icon: .uploadLocal) { resolve(.uploadLocal) }
                    Button("用云端数据替换本机…", icon: .replaceWithCloud, role: .destructive) { confirmErase = true }
                } else {
                    Button("立即同步", icon: .syncNow) { Task { await services.syncNow() } }
                        .disabled(!services.canSyncNow)
                }
                if !services.conflicts.isEmpty {
                    NavigationLink(value: Route.conflicts) {
                        Label("\(services.conflicts.count) 条灵感或任务有两个版本", icon: .conflict)
                            .foregroundStyle(palette.ink)
                    }
                }
                if !services.syncIssues.isEmpty {
                    DisclosureGroup("\(services.syncIssues.count) 条记录没能同步") {
                        ForEach(Array(services.syncIssues.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.summary).font(.footnote)
                                Text(issue.message).font(.caption2.monospaced()).foregroundStyle(palette.ink3).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("iCloud 同步")
        } footer: {
            if case .needsDecision = services.syncStatus {
                Text("上传：本机数据作为新内容传到当前账号。替换：丢弃本机的灵感、任务、项目与图片，从当前账号的云端重新下载。")
            }
        }
        .confirmationDialog("丢弃本机数据，改用云端的？", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("用云端数据替换本机", role: .destructive) { resolve(.eraseLocal) }
        } message: {
            Text("本机的灵感、任务、项目与图片会被删除，无法撤销。")
        }
    }

    private func resolve(_ resolution: SyncResolution) {
        let done: Dotted = if case .uploadLocal = resolution { "已开始上传本机数据" } else { "正在从云端重新下载" }
        workspace.attempt {
            try await services.resolveSync(resolution)
            workspace.say(done)
        }
    }
}
#endif
