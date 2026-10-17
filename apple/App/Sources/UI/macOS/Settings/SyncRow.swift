#if os(macOS)
import CueSync
import SwiftUI

/// iCloud 同步那一行。状态字只说现状（`SyncSummary`），有解决办法时后面给一个链接：
/// 没开 iCloud → 打开系统设置；暂停等你决定 → "处理…"弹出两个选择（替换本机前再确认一次）；有记录没能同步 → "查看"明细。
/// 能自己好起来的（账号受限、暂时不可用、空间不足）把原因直接写在状态里；右边常驻"立即同步"。
struct SyncRow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    @State private var working = false
    @State private var failure: String?
    @State private var showsDecision = false
    @State private var showsIssues = false
    @State private var confirmErase = false

    /// 系统设置的 Apple 账户（iCloud 的开关在里面）。
    private static let accountSettings = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!

    private enum Fix { case decide, openSettings, issues }

    var body: some View {
        let summary = SyncSummary(services.syncStatus)
        let fix = fix
        SettingRow(
            title: "iCloud 同步", icon: Image(systemName: summary.symbol), tone: tone(summary), busy: services.isSyncBusy, status: status(summary, fix: fix),
            help: fix == nil ? nil : summary.detail
        ) {
            if services.sync != nil, fix != .decide, fix != .openSettings {
                Button("立即同步") { Task { await services.syncNow() } }
                    .settingButton()
                    .disabled(!services.canSyncNow)
            }
        } fix: {
            switch fix {
            case .decide:
                Button("处理…") { showsDecision = true }
                    .settingFix()
                    .popover(isPresented: $showsDecision, arrowEdge: .bottom) { decision(summary) }
            case .openSettings:
                Button("打开系统设置") { openURL(Self.accountSettings) }.settingFix()
            case .issues:
                Button("查看") { showsIssues = true }
                    .settingFix()
                    .popover(isPresented: $showsIssues, arrowEdge: .bottom) { issues }
            case nil:
                EmptyView()
            }
        }
        .dialog("丢弃本机数据，改用云端的？", isPresented: $confirmErase, message: "本机的灵感、任务、项目与图片会被删除，无法撤销。", buttons: [
            DialogButton(title: "用云端数据替换本机", role: .destructive) { resolve(.eraseLocal) }
        ])
    }

    private var fix: Fix? {
        switch services.syncStatus {
        case .needsDecision: .decide
        case .noAccount: .openSettings
        default: services.syncIssues.isEmpty ? nil : .issues
        }
    }

    private func tone(_ summary: SyncSummary) -> StatusTone {
        failure != nil || !services.syncIssues.isEmpty ? .failure : summary.tone
    }

    private func status(_ summary: SyncSummary, fix: Fix?) -> Dotted {
        if let failure { return Dotted(failure) }
        return switch fix {
        case .issues: Dotted(summary.title, "\(services.syncIssues.count) 条记录没能同步")
        case .decide, .openSettings: Dotted(summary.title)
        case nil: Dotted(summary.title, summary.detail)
        }
    }

    private func decision(_ summary: SyncSummary) -> some View {
        SettingPopover(title: "同步已暂停") {
            if let detail = summary.detail { Text(detail).foregroundStyle(palette.ink2) }
            choice("上传本机数据", "本机数据作为新内容传到当前账号", primary: true) {
                showsDecision = false
                resolve(.uploadLocal)
            }
            choice("用云端数据替换本机…", "丢弃本机的灵感、任务、项目与图片，从当前账号的云端重新下载", destructive: true) {
                showsDecision = false
                confirmErase = true
            }
        }
        .disabled(working)
    }

    private func choice(
        _ title: String, _ consequence: String, primary: Bool = false, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 会删东西的那颗字用胭脂，与确认框里同一颗一致
            Button(action: action) { Text(title).foregroundStyle(destructive ? palette.failure : primary ? palette.onFill : palette.ink) }
                .settingButton(primary: primary)
            Text(consequence).font(Typography.meta).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var issues: some View {
        SettingPopover(title: "\(services.syncIssues.count) 条记录没能同步", width: 400) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(services.syncIssues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.summary).font(Typography.meta).foregroundStyle(palette.ink)
                            Text(issue.message).font(Typography.meta.monospaced()).foregroundStyle(palette.ink3).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            Text(SyncSummary.failedDetail).font(Typography.meta).foregroundStyle(palette.ink3)
        }
    }

    private func resolve(_ resolution: SyncResolution) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do { try await services.resolveSync(resolution) } catch { failure = error.localizedDescription }
        }
    }
}
#endif
