#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// 设置：外观、iCloud 同步（状态、需要你决定的情况、问题明细）、冲突副本、启动时没完成的事；版本写在最底下。
struct SettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 宽屏上表单限宽居中，分段控件与说明不被拉成一长条。
    private static let readableWidth: CGFloat = 640

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Group {
                Section {
                    // 与下面的同步状态一样带图标，两节的行首对齐
                    Picker(selection: $settings.theme) {
                        Text("跟随系统").tag(AppSettings.Theme.system)
                        Text("浅色").tag(AppSettings.Theme.light)
                        Text("深色").tag(AppSettings.Theme.dark)
                    } label: {
                        Label("外观", systemImage: "sun.max")
                    }
                }
                SyncSection()
                if services.sync != nil || Self.previewsAlerts { AlertSection() }
                if !services.conflicts.isEmpty {
                    Section {
                        NavigationLink(value: Route.conflicts) {
                            Label("\(services.conflicts.count) 条灵感或任务有两个版本", systemImage: "square.on.square")
                                .foregroundStyle(palette.ink)
                        }
                    }
                }
                if !services.startupIssues.isEmpty {
                    Section("没能完成的事") {
                        ForEach(Array(services.startupIssues.enumerated()), id: \.offset) { _, issue in
                            Label(issue.text, systemImage: "exclamationmark.triangle").font(.footnote)
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

    /// 演示模式没有同步引擎：调试参数要看"Pi 通知"各状态时照样显示这一节。
    private static var previewsAlerts: Bool { DebugHooks.preset.alertStatus != nil }
}

/// Pi 通知：一行状态（权限、推送注册、服务端订阅哪一步不通就写哪一步），能在这里解决的给按钮。
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
                Image(systemName: status.state == .on ? "bell.badge" : status.state == .pending ? "bell" : "bell.slash")
                    .foregroundStyle(status.state == .problem ? palette.failure : palette.ink2)
            }
            if let diagnostics = status.diagnostics {
                DisclosureGroup("详情") {
                    Text(diagnostics).font(.caption.monospaced()).foregroundStyle(palette.ink3).textSelection(.enabled)
                }
            }
            switch status.action {
            case .retry:
                Button("重试", systemImage: "arrow.clockwise") {
                    alerts.retryRegistration()
                    Task { await services.syncNow() }
                }
            case .openSettings:
                Button("打开系统通知设置", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            case .allow:
                Button("开启通知", systemImage: "bell") { Task { await alerts.requestAuthorization() } }
            case nil:
                EmptyView()
            }
        } header: {
            Text("Agent 通知")
        }
    }
}

/// iCloud 同步：一行状态，需要决定时给出两个选择，问题明细可展开。
private struct SyncSection: View {
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var confirmErase = false
    @State private var syncing = false

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
                if services.syncStatus == .syncing {
                    Spinner(.small)
                } else {
                    Image(systemName: summary.symbol).foregroundStyle(palette.color(summary.tone))
                }
            }
            if services.sync != nil {
                if case .needsDecision = services.syncStatus {
                    Button("上传本机数据", systemImage: "icloud.and.arrow.up") { resolve(.uploadLocal) }
                    Button("用云端数据替换本机…", systemImage: "icloud.and.arrow.down", role: .destructive) { confirmErase = true }
                } else {
                    Button("立即同步", systemImage: "arrow.triangle.2.circlepath") {
                        syncing = true
                        Task {
                            await services.refresh()
                            syncing = false
                        }
                    }
                    .disabled(syncing || services.syncStatus == .syncing)
                    MacConnectionTest()
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
