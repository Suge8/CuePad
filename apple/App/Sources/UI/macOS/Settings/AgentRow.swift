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
/// 没装、太旧的给"安装""升级"：同接入面板，在后台跑官方安装脚本（`AppServices.installAgent`，进度与没装上的原因在 `AgentIntegrations.jobs`，
/// 两处读同一份），缺前提的（Pi 要 Node.js）给官网。正常的行是安静的，只有要你动手的（别人的同名文件、Pi 太旧）变色。
/// 怎么用、会写在哪、何时生效、安装跑的命令放在悬停提示里。出现时重新检测它（用户可能刚在终端里装好）。
struct AgentRow: View {
    let kind: AgentKind
    @Environment(AppServices.self) private var services
    @State private var working = false
    @State private var outcome: Outcome?

    private enum Outcome: Equatable {
        case failed(String)
    }

    var body: some View {
        let status = services.agents.status(kind)
        let (tone, line) = describe(status)

        SettingRow(title: .verbatim(kind.name), icon: kind.mark.image, tone: tone, busy: working || installing, status: line, help: help) {
            // 开关常驻：检测中与开不了也关不了的（没装、版本不对、开发构建没指定目录、别人的同名文件）置灰，检测完只换状态那一行字
            Toggle(kind.name, isOn: Binding(get: { status?.isConnected ?? false }, set: apply))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(working || !(status.map(canToggle) ?? false))
        } fix: {
            if let status, Self.needsSetup(status), !installing {
                if let prerequisite = status.lacking {
                    Link("去官网", destination: prerequisite.site).settingFix().accessibilityLabel("\(prerequisite.name) 官网")
                } else {
                    Button(kind.upgrades(status.presence) ? "升级" : "安装") { Task { try? await services.installAgent(kind) } }.settingFix()
                }
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
        case .unresponsive: false
        case .notFound: status.files == .missing
        }
    }

    private var installing: Bool { services.agents.jobs[kind] == .installing }

    /// 装的进度与没装上的原因在前（同接入面板那一行），缺前提的写缺什么。
    private func describe(_ status: AgentStatus?) -> (StatusTone, Dotted?) {
        if case .failed(let message) = outcome { return (.failure, Dotted(message)) }
        if installing { return (.calm, Dotted(AgentLine.installing)) }
        if let status, Self.needsSetup(status) {
            if case .failed(let why) = services.agents.jobs[kind] { return (.failure, Dotted(AgentLine.notInstalled(why))) }
            if let prerequisite = status.lacking { return (.notice, Dotted(AgentLine.needs(prerequisite))) }
        }
        return AgentLine.of(kind, status, writable: services.agents.isWritable(kind))
    }

    /// 一句一行：中文句间不留空格、英文要，换行两边都对
    private var help: LocalizedStringResource {
        let files = services.agents.writtenFiles(kind).joined(separator: String(localized: "、"))
        let name = kind.name
        let lines = [
            kind == .pi
                ? String(localized: "接入后，在终端里开的 \(name) 会话也出现在 CuePad 里：在 Mac 和手机上看它在做什么、发话、回答它的提问。")
                : String(localized: "接入后，在终端和桌面版里开的 \(name) 会话也出现在 CuePad 里：在 Mac 和手机上看它在做什么、发话、回答它的提问。"),
            kind == .pi ? String(localized: "CuePad 在后台开 Pi 会话也要先接入。") : String(localized: "不接入也能让 CuePad 在后台开 \(name) 会话。"),
            kind.limits,
            String(localized: "它也学会用 cuepad 记灵感、看和改任务，把页面和截图发到手机上看。"),
            kind == .codex ? String(localized: "Codex 在沙箱里跑命令，写入 CuePad 时会请你批准。") : nil,
            kind == .opencode ? String(localized: "会话直连 OpenCode 的后台服务，不用另装。") : nil,
            String(localized: "会写入 \(files)（配置文件里只加 CuePad 自己的条目）；关掉即删除。"),
            kind == .pi ? String(localized: "接入后运行中的会话 /reload 后生效。") : String(localized: "接入后新开的会话里生效。"),
            services.agents.status(kind).map { String(localized: "安装、升级在后台运行官方命令：\(kind.installCommand($0.presence))") },
        ]
        return "\(lines.compactMap { $0 }.joined(separator: "\n"))"
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
/// 在装、没装上、缺前提的那几句两处同一份。
enum AgentLine {
    static var installing: String { String(localized: "安装中，可能要几分钟") }
    /// 原因是安装脚本的最后一句原话
    static func notInstalled(_ why: String) -> String { String(localized: "没装上：\(why)") }

    static func needs(_ prerequisite: InstallPrerequisite) -> String {
        let version = "\(prerequisite.minimum.major).\(prerequisite.minimum.minor)"
        return String(localized: "需要 \(prerequisite.name) \(version) 以上")
    }

    static func of(_ kind: AgentKind, _ status: AgentStatus?, writable: Bool) -> (StatusTone, Dotted?) {
        guard let status else { return (.calm, Dotted(String(localized: "检测中…"))) }
        guard writable else { return (.calm, Dotted(String(localized: "正式版在用，先用 \(kind.homeVariable) 指定目录"))) }
        switch (status.presence, status.files) {
        case (_, .foreign(let path)): return (.failure, Dotted(String(localized: "\(path) 是别人的同名文件，没有改动")))
        case (.tooOld(let version), _) where kind == .opencode: return (.notice, Dotted(String(localized: "需要 OpenCode 2，现在是 \(version.description)")))
        case (.tooOld(let version), _): return (.notice, Dotted(String(localized: "\(version.description) 太旧，需要 \(kind.minimumVersion.map(\.description) ?? "") 或更新")))
        case (.unresponsive, _): return (.notice, Dotted(String(localized: "找到了，但问版本没有回应，稍后再看")))
        case (.notFound, .missing): return (.calm, Dotted(String(localized: "没有检测到")))
        case (.notFound, _): return (.calm, Dotted(String(localized: "已卸载，CuePad 的技能还留着")))
        case (.found, .missing): return (.calm, Dotted(kind.writes))
        case (.found, .outdated): return (.notice, Dotted(String(localized: "需要升级")))
        case (.found(let version), .current): return (.calm, Dotted(String(localized: "已接入"), version.map { "\(kind.name) \($0)" }))
        }
    }
}

extension AgentKind {
    /// 接入会写什么（没接入时那一行的状态；能做什么写在接入面板的说明与悬停提示里）
    var writes: String {
        switch self {
        case .pi: String(localized: "写入扩展与技能")
        case .claudeCode, .codex: String(localized: "写入技能与钩子")
        case .opencode: String(localized: "写入技能，直连它的后台服务")
        }
    }

    /// 悬停提示里的一句：终端里开的会话从 CuePad 做不到的（由 `AgentCapabilities.of` 推出；CuePad 在后台开的什么都能做）
    var limits: String? {
        let missing = AgentCapabilities.all.subtracting(.of(self, hosted: false, model: nil))
        let names: [(AgentCapabilities, String)] = [
            (.images, String(localized: "发图片")), (.abort, String(localized: "中途停下")), (.model, String(localized: "切换模型")),
            (.rename, String(localized: "改会话名")), (.commands, String(localized: "用斜杠命令")), (.answer, String(localized: "回答提问")),
            (.end, String(localized: "结束这个会话")),
        ]
        let lacking = names.filter { missing.contains($0.0) }.map(\.1)
        return lacking.isEmpty ? nil : String(localized: "终端里开的会话不能\(lacking.joined(separator: String(localized: "、")))，CuePad 在后台开的都能做。")
    }
}

#endif
