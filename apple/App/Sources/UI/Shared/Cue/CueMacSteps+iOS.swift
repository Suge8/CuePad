#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// 手机上启用 Cue 前的三步：在 Mac 上装 CuePad、两台登同一个 iCloud、在 Mac 上接入 Agent。Cue 和 Agent 都在 Mac 上，手机只经 iCloud 看到它们，
/// 每一步都只按同步来的事实算，不另记"做过哪步"：
/// - 装好：库里有 Mac 写下过自己（`CueSettings.macs`）；
/// - 对上：同步此刻到得了 Mac（`SyncStatus.reachesMac`）、和 iCloud 对过一遍（`CueGate.waiting` 为空），且库里有 Mac——同一个账户才看得到它；
/// - 接好：有一台 Mac 报了能用的 Agent（`MacAgents.agents`）。
/// 卡住的只有一步（`stuck`）：同步不通时一定是 iCloud（装没装 Mac 这时看不出），不然按顺序第一个没成的。
/// 同步不通的说法与出路只用设置里同步那一行的（`SyncSummary`）。
nonisolated struct CueMacSetup: Equatable {
    enum Step: Int, CaseIterable { case install, iCloud, agents }

    let macs: [MacAgents]
    let status: SyncStatus
    /// 还没和 iCloud 对过时在等什么（`CueGate.waitingReason`）。
    let waiting: String?

    var installed: Bool { !macs.isEmpty }
    var reaches: Bool { status.reachesMac && waiting == nil }
    var agents: [AgentKind] { AgentKind.allCases.filter { kind in macs.contains { $0.kinds.contains(kind) } } }

    /// 卡住的那一步；三步都通为 nil（这时是启用钮）。
    var stuck: Step? {
        if !reaches { return .iCloud }
        if !installed { return .install }
        return agents.isEmpty ? .agents : nil
    }

    func done(_ step: Step) -> Bool {
        switch step {
        case .install: installed
        case .iCloud: reaches && installed
        case .agents: !agents.isEmpty
        }
    }
}

/// 三步一列，卡住的那一步亮起、带它的动作；三步都通时换成启用（`finish`）。卡底一句没有 Mac 时能先做什么。
struct CueMacSteps<Finish: View>: View {
    let setup: CueMacSetup
    @ViewBuilder var finish: Finish
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    var body: some View {
        if setup.stuck == nil {
            finish
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(CueMacSetup.Step.allCases, id: \.self, content: row)
                Text("没有 Mac 也能先用：记灵感、建任务，Mac 接上后接着做")
                    .font(Typography.meta).foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 340)
        }
    }

    private func row(_ step: CueMacSetup.Step) -> some View {
        let done = setup.done(step), lit = setup.stuck == step
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if done {
                    Image(.done).foregroundStyle(palette.ink2)
                } else {
                    Text(step.rawValue + 1, format: .number).monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(lit ? palette.signature : palette.ink3)
                }
            }
            .font(Typography.meta)
            .frame(width: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(step)).font(Typography.secondary.weight(lit ? .semibold : .regular))
                        .foregroundStyle(lit || done ? palette.ink : palette.ink3)
                    HStack(spacing: 6) {
                        if lit, step == .iCloud, setup.waiting != nil { Spinner(.mini) }
                        Text(detail(step, done: done)).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Typography.meta).foregroundStyle(lit ? palette.ink2 : palette.ink3)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(done ? String(localized: "已完成") : lit ? String(localized: "卡在这一步") : "")
                if lit { action(step).padding(.top, 4) }
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ step: CueMacSetup.Step) -> LocalizedStringResource {
        switch step {
        case .install: "在 Mac 上装 CuePad"
        case .iCloud: "两台登同一个 iCloud"
        case .agents: "在 Mac 上接入 Agent"
        }
    }

    private func detail(_ step: CueMacSetup.Step, done: Bool) -> String {
        switch step {
        case .install:
            done ? setup.macs.map(\.shownName).formatted(.list(type: .and)) : String(localized: "手机记事、拍板，Agent 在 Mac 上干活")
        case .iCloud:
            if let waiting = setup.waiting { waiting }
            else if !setup.status.reachesMac { SyncSummary(setup.status).line }
            else if done { SyncSummary(setup.status).title }
            else { String(localized: "登好后 Mac 会出现在这里") }
        case .agents:
            if done { setup.agents.map(\.name).formatted(.list(type: .and)) }
            else if let mac = setup.macs.first { String(localized: "\(mac.shownName)：\(mac.whyNone)") }
            else { String(localized: "在 Mac 的 CuePad 里接入 \(AgentKind.allCases.map(\.name).formatted(.list(type: .or)))") }
        }
    }

    /// 卡住那一步的出路：发出下载链接、没开 iCloud 时打开设置；还在对时只转圈（在说明那一行）、Agent 只能在 Mac 上接，没有动作。
    @ViewBuilder private func action(_ step: CueMacSetup.Step) -> some View {
        switch step {
        case .install:
            ShareLink(item: CueSettings.macDownload) { Label("发出 Mac 版的下载链接", icon: .share) }
                .buttonStyle(ControlButtonStyle(kind: .primary))
        case .iCloud:
            if setup.waiting == nil, setup.status == .noAccount {
                Button(SyncSummary.settingsTitle) { openURL(SyncSummary.settings) }
                    .buttonStyle(ControlButtonStyle(kind: .primary))
            }
        case .agents:
            EmptyView()
        }
    }
}
#endif
