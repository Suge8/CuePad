#if os(macOS)
import CueSync
import SwiftUI

struct SyncRow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    @State private var choices = SyncChoices()
    @State private var showsDecision = false
    @State private var showsIssues = false
    @State private var confirmErase = false
    @State private var syncLasts = false

    private enum Fix { case decide, openSettings, update, issues }

    var body: some View {
        let shown = ShownSync(services, lasting: syncLasts), summary = shown.summary
        let fix = fix
        SettingRow(
            title: "iCloud 同步", icon: Image(summary.icon), tone: tone(summary), busy: shown.busy, status: status(summary),
            help: summary.detail.map { "\($0)" }
        ) {
            if services.syncing.canSyncNow {
                Button("立即同步") { Task { await services.syncing.syncNow() } }
                    .buttonStyle(ControlButtonStyle(size: .compact))
                    .disabled(services.syncing.isSyncingNow)
            }
        } fix: {
            switch fix {
            case .decide:
                Button("处理…") { showsDecision = true }
                    .settingFix()
                    .popover(isPresented: $showsDecision, arrowEdge: .bottom) { decision(summary) }
            case .openSettings:
                Button(SyncSummary.settingsTitle) { openURL(SyncSummary.settings) }.settingFix()
            case .update:
                Button(SyncSummary.updateTitle) { services.updates.checkForUpdates() }.settingFix()
            case .issues:
                Button("查看") { showsIssues = true }
                    .settingFix()
                    .popover(isPresented: $showsIssues, arrowEdge: .bottom) { issues }
            case nil:
                EmptyView()
            }
        }
        .lineLimit(1)
        .confirmsErase($confirmErase, choices: choices, services: services)
        .pending(services.syncing.state.status == .syncing, shown: $syncLasts)
    }

    private var fix: Fix? {
        switch services.syncing.state.status {
        case .needsDecision: .decide
        case .noAccount: .openSettings
        case .outdated: .update
        default: services.syncing.state.issues.isEmpty ? nil : .issues
        }
    }

    private func tone(_ summary: SyncSummary) -> StatusTone {
        choices.failure != nil || !services.syncing.state.issues.isEmpty ? .failure : summary.tone
    }

    private func status(_ summary: SyncSummary) -> Dotted {
        if let failure = choices.failure { return Dotted(failure) }
        if fix == .issues { return Dotted(String(localized: "\(summary.title)，\(services.syncing.state.issues.count) 条记录没能同步")) }
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
        VStack(alignment: .leading, spacing: Spacing.tight) {
            // 会删东西的那颗字用胭脂，与确认框里同一颗一致
            Button(action: action) { Text(choice.title).foregroundStyle(destructive ? palette.failure : primary ? palette.onFill : palette.ink) }
                .buttonStyle(ControlButtonStyle(kind: primary ? .primary : .secondary, size: .compact))
            Text(choice.consequence).font(Typography.meta).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var issues: some View {
        SettingPopover(title: "\(services.syncing.state.issues.count) 条记录没能同步", width: 400) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.group) {
                    ForEach(Array(services.syncing.state.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: Spacing.hair) {
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
