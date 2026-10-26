#if os(macOS)
import CueSync
import SwiftUI

/// iCloud 同步那一行。状态字只写现状的标题（`SyncSummary`），补充说明在悬停提示里；有解决办法时后面给一个链接：
/// 没开 iCloud → 打开系统设置；暂停等你决定 → "处理…"弹出两个选择（替换本机前再确认一次）；有记录没能同步 → "查看"明细。
/// 按了有用时右边给"立即同步"（`AppServices.canSyncNow`）。
struct SyncRow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    @State private var choices = SyncChoices()
    @State private var showsDecision = false
    @State private var showsIssues = false
    @State private var confirmErase = false
    /// 这一轮同步中已久过 `Pending.delay`（`AppServices.shownSync`）。
    @State private var syncLasts = false

    private enum Fix { case decide, openSettings, issues }

    var body: some View {
        let shown = services.shownSync(lasting: syncLasts), summary = shown.summary
        let fix = fix
        SettingRow(
            title: "iCloud 同步", icon: Image(summary.icon), tone: tone(summary), busy: shown.busy, status: status(summary),
            help: summary.detail.map { "\($0)" }
        ) {
            if services.canSyncNow {
                Button("立即同步") { Task { await services.syncNow() } }
                    .settingButton()
                    .disabled(services.isSyncingNow)
            }
        } fix: {
            switch fix {
            case .decide:
                Button("处理…") { showsDecision = true }
                    .settingFix()
                    .popover(isPresented: $showsDecision, arrowEdge: .bottom) { decision(summary) }
            case .openSettings:
                Button(SyncSummary.settingsTitle) { openURL(SyncSummary.settings) }.settingFix()
            case .issues:
                Button("查看") { showsIssues = true }
                    .settingFix()
                    .popover(isPresented: $showsIssues, arrowEdge: .bottom) { issues }
            case nil:
                EmptyView()
            }
        }
        // 状态始终有一行：短句不留额外空白，长句截断；完整说明在悬停提示里。
        .lineLimit(1)
        .confirmsErase($confirmErase, choices: choices, services: services)
        .pending(services.syncStatus == .syncing, shown: $syncLasts)
    }

    private var fix: Fix? {
        switch services.syncStatus {
        case .needsDecision: .decide
        case .noAccount: .openSettings
        default: services.syncIssues.isEmpty ? nil : .issues
        }
    }

    private func tone(_ summary: SyncSummary) -> StatusTone {
        choices.failure != nil || !services.syncIssues.isEmpty ? .failure : summary.tone
    }

    private func status(_ summary: SyncSummary) -> Dotted {
        if let failure = choices.failure { return Dotted(failure) }
        if fix == .issues { return Dotted(String(localized: "\(summary.title)，\(services.syncIssues.count) 条记录没能同步")) }
        return Dotted(summary.title)
    }

    private func decision(_ summary: SyncSummary) -> some View {
        SettingPopover(title: "同步已暂停") {
            if let detail = summary.detail { Text(detail).foregroundStyle(palette.ink2) }
            choice(SyncChoices.upload, primary: true) {
                showsDecision = false
                choices.resolve(.uploadLocal, services)
            }
            choice(SyncChoices.erase, destructive: true) {
                showsDecision = false
                confirmErase = true
            }
        }
        .disabled(choices.working)
    }

    private func choice(
        _ choice: SyncChoices.Choice, primary: Bool = false, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 会删东西的那颗字用胭脂，与确认框里同一颗一致
            Button(action: action) { Text(choice.title).foregroundStyle(destructive ? palette.failure : primary ? palette.onFill : palette.ink) }
                .settingButton(primary: primary)
            Text(choice.consequence).font(Typography.meta).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var issues: some View {
        SettingPopover(title: "\(services.syncIssues.count) 条记录没能同步", width: 400) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(services.syncIssues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.text).font(Typography.meta).foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true)
                            if let detail = issue.detail {
                                DisclosureGroup("详情") {
                                    Text(detail).font(Typography.meta.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(Typography.meta).foregroundStyle(palette.ink3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
