#if os(iOS)
import CueSync
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        SettingsForm {
            CueSettingsSection()
            SyncSection()
            if services.sync != nil || Self.previewsAlerts { AlertSection() }
            Section {
                if typeSize.isAccessibilitySize {
                    ThemePicker()
                } else {
                    LabeledContent {
                        ThemePicker()
                    } label: {
                        Label("外观", icon: .appearance)
                    }
                }
                LanguageRow()
                SoundToggle()
            }
            if !services.startupIssues.isEmpty {
                Section("启动问题") {
                    ForEach(Array(services.startupIssues.enumerated()), id: \.offset) { _, issue in
                        Label { Text(issue.text) } icon: { FailureMark() }.font(Typography.meta)
                    }
                }
            }
            if services.diagnostics.latest != nil || services.diagnostics.canSend {
                Section {
                    LastCrashRow()
                    if services.diagnostics.canSend { SendLogsRow() }
                } footer: {
                    if services.diagnostics.canSend { Text(SendLogsRow.note).lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Section {} footer: {
                Text("CuePad \(AppServices.version)").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingHeader("设置")
    }

    /// 演示模式没有同步：调试参数要看通知各状态时照样显示这一节。
    private static var previewsAlerts: Bool { DebugHooks.preset.alertStatus != nil }
}

struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass

    private static var readableWidth: CGFloat { Spacing.reading }

    var body: some View {
        Form {
            Group { content }.listRowBackground(palette.paper)
        }
        .frame(maxWidth: sizeClass == .regular ? Self.readableWidth : .infinity)
        .frame(maxWidth: .infinity)
        .scrollContentBackground(.hidden)
    }
}

/// 设置里一行状态的标题与下面的说明。说明按 `reserve`（会自己来去的那一句：连不上 iCloud）留出高度，此刻没说明或说明更短时留白：
/// 断开、连上不是用户做的，说明一出一收整页的行就跟着跳。比它长的（要你处理的几种，不会自己来去）照常撑高。
private struct StatusText: View {
    let title: String
    let detail: String?
    let reserve: String?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            Text(title)
            ZStack(alignment: .topLeading) {
                Text(reserve ?? "").hidden()
                if let detail { Text(detail) }
            }
            .font(Typography.meta).foregroundStyle(palette.ink3)
        }
    }
}

private struct AlertSection: View {
    @Environment(AppServices.self) private var services
    @Environment(AlertCenter.self) private var alerts
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    var body: some View {
        let live = AlertStatus(
            authorization: alerts.authorization, registration: alerts.registration, subscription: services.syncing.state.alerts)
        let status = DebugHooks.preset.alertStatus ?? live
        Section {
            Label {
                StatusText(title: status.title, detail: status.detail, reserve: AlertStatus.offline.detail)
            } icon: {
                Image(status.state == .on ? .alertsOn : status.state == .pending ? .alertsPending : .alertsOff)
                    .foregroundStyle(status.state == .problem ? palette.failure : palette.ink2)
            }
            if let diagnostics = status.diagnostics {
                DisclosureGroup("详情") {
                    Text(diagnostics).font(Typography.caption.monospaced()).foregroundStyle(palette.ink3).textSelection(.enabled)
                }
            }
            switch status.action {
            case .retry:
                Button("重试", icon: .retry) {
                    alerts.retryRegistration()
                    Task { await services.syncing.syncNow() }
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

private struct SyncSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    @State private var choices = SyncChoices()
    @State private var confirmErase = false

    var body: some View {
        Section {
            let summary = SyncSummary(services.syncing.state.status)
            Label {
                StatusText(title: summary.title, detail: summary.detail, reserve: SyncSummary(.offline).detail)
            } icon: {
                if services.syncing.isSyncBusy {
                    Spinner(.small)
                } else {
                    Image(summary.icon).foregroundStyle(palette.color(summary.tone))
                }
            }
            if case .needsDecision = services.syncing.state.status {
                Group {
                    Button(SyncChoices.upload.title, icon: .uploadLocal) { choices.resolve(.uploadLocal, services) }
                    Button(SyncChoices.erase.title, icon: .replaceWithCloud, role: .destructive) { confirmErase = true }
                }
                .disabled(choices.working)
            } else if services.syncing.state.status == .noAccount {
                Button(SyncSummary.settingsTitle, icon: .settings) { openURL(SyncSummary.settings) }
            } else if services.syncing.state.status == .outdated {
                Button(SyncSummary.updateTitle, icon: .updates) { openURL(SyncSummary.update) }
            } else if services.syncing.canSyncNow {
                Button("立即同步", icon: .syncNow) { Task { await services.syncing.syncNow() } }
                    .disabled(services.syncing.isSyncingNow)
            }
            if let failure = choices.failure {
                Label { Text(failure).font(Typography.meta) } icon: { FailureMark() }
            }
            if services.syncing.state.filesOverQuota {
                Label { Text(FileStatus.overQuota).font(Typography.meta) } icon: { Image(.syncPaused).foregroundStyle(palette.color(.notice)) }
            }
            if !services.syncing.conflicts.isEmpty {
                NavigationLink(value: Route.conflicts) {
                    Label("\(services.syncing.conflicts.count) 条灵感或任务有两个版本", icon: .conflict)
                        .foregroundStyle(palette.ink)
                }
            }
            if !services.syncing.state.issues.isEmpty {
                DisclosureGroup("\(services.syncing.state.issues.count) 条记录没能同步") {
                    ForEach(Array(services.syncing.state.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.text).font(Typography.meta)
                        if let detail = issue.detail {
                            DisclosureGroup("详情") {
                                Text(detail).font(Typography.caption2.monospaced()).foregroundStyle(palette.ink3).textSelection(.enabled)
                            }
                            .font(Typography.meta).foregroundStyle(palette.ink3)
                        }
                    }
                }
            }
        } header: {
            Text("iCloud 同步")
        } footer: {
            if case .needsDecision = services.syncing.state.status {
                Text("上传：\(SyncChoices.upload.consequence)。替换：\(SyncChoices.erase.consequence)。")
            }
        }
        .confirmsErase($confirmErase, choices: choices, services: services)
    }
}
#endif
