#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 设置里的 Agent 那几行（`AgentRow`）。
struct AgentRows: View {
    var body: some View {
        ForEach(AgentKind.allCases) { AgentRow(kind: $0) }
    }
}

/// 一个 Agent 一行：开关即接入（写技能；Pi 另写扩展，Claude Code、Codex 另写钩子，OpenCode 直连它的后台服务）或删除（CuePad 写的文件与因此空出的目录）。状态写它在不在、接没接（`AgentLine`）；
/// 没装的给"安装方法"。正常的行是安静的，只有要你动手的（别人的同名文件、Pi 太旧）变色。怎么用、会写在哪、何时生效放在悬停提示里。
/// 出现时重新检测它（用户可能刚在终端里装好）。
struct AgentRow: View {
    let kind: AgentKind
    @Environment(AppServices.self) private var services
    @State private var working = false
    @State private var outcome: Outcome?
    @State private var showsGuide = false

    private enum Outcome: Equatable {
        case failed(String)
    }

    var body: some View {
        let status = services.agents.status(kind)
        let (tone, line) = describe(status)

        SettingRow(title: kind.name, icon: kind.mark.image, tone: tone, busy: working, status: line, help: help) {
            // 开不了也关不了的（没装、版本不对、开发构建没指定目录、别人的同名文件）不给开关，免得像是能点
            if let status, canToggle(status) {
                Toggle(kind.name, isOn: Binding(get: { status.isConnected }, set: apply))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(working)
            }
        } fix: {
            if let status, Self.needsSetup(status) {
                Button(kind.upgrades(status.presence) ? "升级方法" : "安装方法") { showsGuide = true }
                    .settingFix()
                    .popover(isPresented: $showsGuide, arrowEdge: .bottom) { AgentSetupGuide(kind: kind, presence: status.presence) }
            }
        }
        .task { await services.agents.detect(kind) }
    }

    /// 别人的同名文件不碰；开发构建不写真实配置目录；没装的 Agent 不接，但它卸掉后留下的 CuePad 技能能关掉删除。
    private func canToggle(_ status: AgentStatus) -> Bool {
        guard services.agents.isWritable(kind) else { return false }
        if case .foreign = status.files { return false }
        return status.isAvailable || status.files != .missing
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
        return AgentLine.of(kind, status, writable: services.agents.isWritable(kind))
    }

    private var help: String {
        let files = services.agents.writtenFiles(kind).joined(separator: "、")
        return [
            "接入后，在\(kind == .pi ? "终端" : "终端和桌面版")里开的 \(kind.name) 会话也出现在 CuePad 里：在 Mac 和手机上看它在做什么、发话、回答它的提问。",
            kind == .pi ? "CuePad 在后台开 Pi 会话也要先接入。" : "不接入也能让 CuePad 在后台开 \(kind.name) 会话。",
            kind.limits,
            "它也学会用 cuepad 记灵感、看和改任务，把页面和截图发到手机上看。",
            kind == .codex ? "Codex 在沙箱里跑命令，写入 CuePad 时会请你批准。" : nil,
            kind == .opencode ? "会话直连 OpenCode 的后台服务，不用另装。" : nil,
            "会写入 \(files)（配置文件里只加 CuePad 自己的条目）；关掉即删除。",
            kind == .pi ? "接入后运行中的会话 /reload 后生效。" : "接入后新开的会话里生效。",
        ].compactMap { $0 }.joined()
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
                } else {
                    try await agents.uninstall(kind)
                }
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        }
    }
}

/// 设置与接入面板里一个 Agent 那一行的状态（`AgentRow`、`SetupPanel`）：接入了的四家同一种写法"已接入 · 名字 版本"，报不出版本的（桌面版）只写"已接入"。
enum AgentLine {
    static func of(_ kind: AgentKind, _ status: AgentStatus?, writable: Bool) -> (StatusTone, Dotted?) {
        guard let status else { return (.calm, "检测中…") }
        guard writable else { return (.calm, Dotted("正式版在用", "先用 \(kind.homeVariable) 指定目录")) }
        switch (status.presence, status.files) {
        case (_, .foreign(let path)): return (.failure, "\(path) 是别人的同名文件，没有改动")
        case (.tooOld(let version), _) where kind == .opencode: return (.notice, "需要 OpenCode 2，现在是 \(version)")
        case (.tooOld(let version), _): return (.notice, "\(version) 太旧，需要 \(kind.minimumVersion.map(\.description) ?? "") 或更新")
        case (.notFound, .missing): return (.calm, "没有检测到")
        case (.notFound, _): return (.calm, "已卸载，CuePad 的技能还留着")
        case (.found, .missing): return (.calm, Dotted(kind.writes))
        case (.found, .outdated): return (.notice, "需要升级")
        case (.found(let version), .current): return (.calm, Dotted("已接入", version.map { "\(kind.name) \($0)" }))
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
        let missing = AgentCapabilities.all.subtracting(.of(self, hosted: false, model: nil))
        let names: [(AgentCapabilities, String)] = [
            (.images, "发图片"), (.abort, "停止"), (.model, "换模型"), (.rename, "改名"),
            (.commands, "用斜杠命令"), (.answer, "作答"), (.end, "结束会话"),
        ]
        let lacking = names.filter { missing.contains($0.0) }.map(\.1)
        return lacking.isEmpty ? nil : "终端里开的会话不能\(lacking.joined(separator: "、"))，CuePad 在后台开的都能做。"
    }
}

#endif
