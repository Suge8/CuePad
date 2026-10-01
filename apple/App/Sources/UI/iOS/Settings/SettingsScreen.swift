#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// 设置：外观、iCloud 同步（状态、需要你决定的情况、问题明细）、冲突副本、启动时没完成的事。
struct SettingsScreen: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.theme) {
                    Text("跟随系统").tag(AppSettings.Theme.system)
                    Text("浅色").tag(AppSettings.Theme.light)
                    Text("深色").tag(AppSettings.Theme.dark)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            SyncSection()
            if !services.conflicts.isEmpty {
                Section {
                    NavigationLink(value: Navigation.Route.conflicts) {
                        Label("\(services.conflicts.count) 张卡片有两个版本", systemImage: "square.on.square")
                            .foregroundStyle(.orange)
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
            Section {
                LabeledContent("版本", value: Self.version)
            }
        }
        .deskBackground()
        .bottomEdgeFade()
        .navigationTitle("设置")
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（\(build)）"
    }
}

/// iCloud 同步：一行状态，需要决定时给出两个选择，问题明细可展开。
private struct SyncSection: View {
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @State private var confirmErase = false
    @State private var syncing = false

    var body: some View {
        Section {
            if services.sync == nil {
                Label("iCloud 同步没有开启", systemImage: "icloud.slash").foregroundStyle(.secondary)
            } else {
                let status = SyncStatusText(services.syncStatus)
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.title)
                        if let detail = status.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                    }
                } icon: {
                    Image(systemName: status.symbol).foregroundStyle(status.tint)
                        .symbolEffect(.pulse, isActive: services.syncStatus == .syncing)
                }
                if case .needsDecision = services.syncStatus {
                    Button("上传本机数据", systemImage: "icloud.and.arrow.up") { resolve(.uploadLocal) }
                    Button("用云端数据替换本机", systemImage: "icloud.and.arrow.down", role: .destructive) { confirmErase = true }
                } else {
                    Button("立即同步", systemImage: "arrow.triangle.2.circlepath") {
                        syncing = true
                        Task {
                            await services.syncNow()
                            syncing = false
                        }
                    }
                    .disabled(syncing || services.syncStatus == .syncing)
                }
                if !services.syncIssues.isEmpty {
                    DisclosureGroup("\(services.syncIssues.count) 条没能同步的记录") {
                        ForEach(Array(services.syncIssues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("iCloud 同步")
        } footer: {
            if case .needsDecision = services.syncStatus {
                Text("上传：本机数据作为新内容传到当前账号。替换：丢弃本机的卡片、项目、任务与图片，从当前账号的云端重新下载。")
            }
        }
        .confirmationDialog("丢弃本机数据，改用云端的？", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("用云端数据替换本机", role: .destructive) { resolve(.eraseLocal) }
        } message: {
            Text("本机的卡片、项目、任务与图片会被删除，无法撤销。")
        }
    }

    private func resolve(_ resolution: SyncResolution) {
        let done = if case .uploadLocal = resolution { "已开始上传本机数据" } else { "正在从云端重新下载" }
        workspace.attempt {
            try await services.resolveSync(resolution)
            workspace.say(done)
        }
    }
}

/// 同步状态给人看的文字与图标。
struct SyncStatusText {
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color

    init(_ status: SyncStatus) {
        switch status {
        case .idle: (title, detail, symbol, tint) = ("已同步", nil, "checkmark.icloud", .green)
        case .syncing: (title, detail, symbol, tint) = ("正在同步…", nil, "arrow.triangle.2.circlepath.icloud", .blue)
        case .noAccount:
            (title, detail, symbol, tint) = ("没有登录 iCloud", "在系统设置里登录后自动开始同步，本机数据不受影响", "icloud.slash", .orange)
        case .accountRestricted:
            (title, detail, symbol, tint) = ("iCloud 账号受限", "家长控制或设备管理限制了 iCloud，本机数据照常可用", "lock.icloud", .orange)
        case .accountUnavailable:
            (title, detail, symbol, tint) = ("iCloud 暂时不可用", "稍后会自动重试", "exclamationmark.icloud", .orange)
        case .quotaExceeded:
            (title, detail, symbol, tint) = ("iCloud 空间不足", "本机改动都已保留，空间释放后自动上传", "exclamationmark.icloud", .orange)
        case .needsDecision(let decision):
            (title, detail, symbol, tint) = ("同步已暂停，需要你决定", Self.describe(decision), "pause.circle", .orange)
        case .failed(let message): (title, detail, symbol, tint) = ("同步出错", message, "xmark.icloud", .red)
        }
    }

    private static func describe(_ decision: SyncDecision) -> String {
        switch decision {
        case .accountSwitched: "iCloud 账号换了，本机数据属于上一个账号"
        case .cloudDataDeleted: "iCloud 里的 CuePad 数据被删除了"
        case .cloudDataReset: "iCloud 里的 CuePad 数据被重置了"
        }
    }
}

extension AppServices.StartupIssue {
    var text: String {
        switch self {
        case .legacyImportFailed(let detail): "旧版数据导入失败：\(detail)"
        case .globalShortcutUnavailable(let detail): "全局快捷键不可用：\(detail)"
        case .captureImportFailed(let detail): "分享进来的内容没能入库（会自动重试）：\(detail)"
        case .syncUnavailable(let detail): "iCloud 同步出了问题：\(detail)"
        case .widgetDataUnavailable(let detail): "小组件数据没能更新：\(detail)"
        }
    }
}
#endif
