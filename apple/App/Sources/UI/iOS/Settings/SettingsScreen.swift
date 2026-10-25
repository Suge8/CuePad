#if os(iOS)
import CueSync
import SwiftUI

/// 设置（项目页末尾、宽屏侧栏底部与 Cue 面板推入），按要紧排，分组与说法同 Mac 设置窗口的通用页：Cue（名字与在哪台 Mac 上运行，`CueSettingsSection`）、
/// iCloud 同步、通知、外观、启动问题、上次崩溃、版本；启动问题与上次崩溃有才出现。
struct SettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        SettingsForm {
            CueSettingsSection()
            SyncSection()
            if services.sync != nil || Self.previewsAlerts { AlertSection() }
            Section {
                LabeledContent {
                    ThemePicker()
                } label: {
                    Label("外观", icon: .appearance)
                }
            }
            if !services.startupIssues.isEmpty {
                Section("启动问题") {
                    ForEach(Array(services.startupIssues.enumerated()), id: \.offset) { _, issue in
                        Label { Text(issue.text) } icon: { FailureMark() }.font(.footnote)
                    }
                }
            }
            if services.diagnostics.latest != nil { Section { LastCrashRow() } }
            Section {} footer: {
                Text("CuePad \(AppServices.version)").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingHeader("设置")
    }

    /// 演示模式没有同步：调试参数要看通知各状态时照样显示这一节。
    private static var previewsAlerts: Bool { DebugHooks.preset.alertStatus != nil }
}

/// 设置页的表单：分组是纸色的行、底是页面色，宽屏上限宽居中（分段控件与说明不被拉成一长条）。
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass

    private static var readableWidth: CGFloat { 640 }

    var body: some View {
        Form {
            Group { content }.listRowBackground(palette.paper)
        }
        .frame(maxWidth: sizeClass == .regular ? Self.readableWidth : .infinity)
        .frame(maxWidth: .infinity)
        .scrollContentBackground(.hidden)
    }
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
    @Environment(\.palette) private var palette
    @State private var choices = SyncChoices()
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
            // 要你决定、冲突与没能同步的记录都只在有同步时出现，按状态排；立即同步要有同步才点得动
            if case .needsDecision = services.syncStatus {
                Group {
                    Button(SyncChoices.upload.title, icon: .uploadLocal) { choices.resolve(.uploadLocal, services) }
                    Button(SyncChoices.erase.title, icon: .replaceWithCloud, role: .destructive) { confirmErase = true }
                }
                .disabled(choices.working)
            } else if services.sync != nil {
                Button("立即同步", icon: .syncNow) { Task { await services.syncNow() } }
                    .disabled(!services.canSyncNow)
            }
            if let failure = choices.failure {
                Label { Text(failure).font(.footnote) } icon: { FailureMark() }
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
        } header: {
            Text("iCloud 同步")
        } footer: {
            if case .needsDecision = services.syncStatus {
                Text("上传：\(SyncChoices.upload.consequence)。替换：\(SyncChoices.erase.consequence)。")
            }
        }
        .confirmsErase($confirmErase, choices: choices, services: services)
    }
}
#endif
