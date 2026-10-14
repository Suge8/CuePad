#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 设置与首次接入面板里的 Agent 那几行（`AgentRow`），两处同一份。
struct AgentRows: View {
    var body: some View {
        ForEach(AgentKind.allCases) { AgentRow(kind: $0) }
    }
}

/// 一个 Agent 一行：开关即接入（写技能；Pi 另写扩展，Claude Code、Codex 另写钩子，OpenCode 直连它的后台服务）或删除（CuePad 写的文件与因此空出的目录）。状态写它在不在、接没接、写在哪；
/// 没装的给"安装方法"。正常的行是安静的，只有要你动手的（别人的同名文件、Pi 太旧）变色。怎么用、会写什么放在悬停提示里。
/// 出现时重新检测它（用户可能刚在终端里装好）。
struct AgentRow: View {
    let kind: AgentKind
    @Environment(AppServices.self) private var services
    @State private var working = false
    @State private var outcome: Outcome?
    @State private var showsGuide = false

    private enum Outcome: Equatable {
        case done(String)
        case failed(String)
    }

    var body: some View {
        let status = services.agents.status(kind)
        let (tone, line) = describe(status)
        SettingRow(title: kind.name, icon: kind.mark.image, tone: tone, busy: working, status: line, help: help) {
            Toggle(kind.name, isOn: Binding(get: { status?.isConnected ?? false }, set: apply))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(working || !(status.map(Self.canToggle) ?? false))
        } fix: {
            if let status, Self.needsSetup(status) {
                Button(status.presence == .notFound ? "安装方法" : "升级方法") { showsGuide = true }
                    .settingFix()
                    .popover(isPresented: $showsGuide, arrowEdge: .bottom) { AgentSetupGuide(kind: kind, presence: status.presence) }
            }
        }
        .task { await services.agents.detect(kind) }
    }

    /// 别人的同名文件不碰；没装的 Agent 不接，但它卸掉后留下的 CuePad 技能能关掉删除。
    private static func canToggle(_ status: AgentStatus) -> Bool {
        status.files != .foreign && (status.isAvailable || status.files != .missing)
    }

    private static func needsSetup(_ status: AgentStatus) -> Bool {
        switch status.presence {
        case .found: false
        case .tooOld: true
        case .notFound: status.files == .missing
        }
    }

    private func describe(_ status: AgentStatus?) -> (StatusTone, Dotted?) {
        if case .failed(let message) = outcome { return (.failure, Dotted(message)) }
        guard let status else { return (.calm, "检测中…") }
        switch (status.presence, status.files) {
        case (_, .foreign): return (.failure, "\(kind == .pi ? "Pi 目录里" : services.agents.skillPath(kind)) 有别人的同名文件，没有改动")
        case (.tooOld(let version), _): return (.notice, "\(version) 太旧，需要 \(PiVersion.minimumSupported) 或更新")
        case (.notFound, .missing): return (.calm, "没有检测到")
        case (.notFound, _): return (.calm, "已卸载，CuePad 的技能还留着")
        case (.found, .missing): return (.calm, Dotted(kind.writes))
        case (.found, .outdated): return (.notice, "需要升级")
        case (.found(let version), .current):
            if case .done(let note) = outcome { return (.calm, Dotted("已接入", note)) }
            return (.calm, Dotted("已接入", version.map { "\(kind.name) \($0)" } ?? services.agents.skillPath(kind)))
        }
    }

    private var help: String {
        let skill = services.agents.skillPath(kind)
        let files = switch kind {
        case .pi: "Pi 目录的 extensions 与 skills 里各一个文件"
        case .claudeCode: "技能 \(skill)，与 \(Self.home(of: skill))/settings.json 里的钩子"
        case .codex: "技能 \(skill)，与 \(Self.home(of: skill))/hooks.json 里的钩子"
        case .opencode: "技能 \(skill)（会话直连 OpenCode 的后台服务，不用另装）"
        }
        return [
            "接入后，\(kind.name) 的会话出现在 CuePad 里：在 Mac 和手机上看它在做什么、发话、回答它的提问，也能让 CuePad 在后台开新会话。",
            kind.limits,
            "它也学会用 cuepad 记灵感、看和改任务，把页面和截图发到手机上看。",
            kind == .codex ? "Codex 在沙箱里跑命令，写入 CuePad 时会请你批准。" : nil,
            "会写入\(files)；关掉即删除。",
        ].compactMap { $0 }.joined()
    }

    /// 技能目录（`<配置目录>/skills/cuepad`）所在的配置目录。
    private static func home(of skill: String) -> String {
        ((skill as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    private func apply(_ on: Bool) {
        working = true
        outcome = nil
        let agents = services.agents, kind = kind
        Task {
            defer { working = false }
            do {
                if on {
                    try await agents.install(kind)
                    outcome = .done(kind == .pi ? "运行中的会话 /reload 后生效" : "新开的会话里生效")
                } else {
                    try await agents.uninstall(kind)
                }
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        }
    }
}

extension AgentKind {
    /// 接入会写什么（没接入时那一行的状态；能做什么写在接入面板的说明与悬停提示里）
    var writes: String {
        switch self {
        case .pi: "写入扩展与技能"
        case .claudeCode, .codex: "写入技能与钩子"
        case .opencode: "写入技能，直连它的后台服务"
        }
    }

    /// 悬停提示里的一句：终端里开的会话从 CuePad 做不到的（由 `AgentCapabilities.of` 推出；CuePad 在后台开的什么都能做）
    var limits: String? {
        let missing = AgentCapabilities.all.subtracting(.of(self, hosted: false))
        let names: [(AgentCapabilities, String)] = [
            (.images, "发图片"), (.steer, "马上说"), (.abort, "停止"), (.model, "换模型"), (.rename, "改名"),
            (.commands, "用斜杠命令"), (.answer, "作答"), (.end, "结束会话"),
        ]
        let lacking = names.filter { missing.contains($0.0) }.map(\.1)
        return lacking.isEmpty ? nil : "终端里开的会话不能\(lacking.joined(separator: "、"))，CuePad 在后台开的都能做。"
    }
}

#endif
