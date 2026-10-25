#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 没装某个 Agent（或版本不对）时的说明（设置里那一行的"安装方法"）：一行可复制的官方安装命令（`InstallCommand`）、官网。
struct AgentSetupGuide: View {
    let kind: AgentKind
    let presence: AgentStatus.Presence
    @Environment(\.palette) private var palette

    var body: some View {
        SettingPopover(title: title) {
            if case .tooOld(let version) = presence {
                let minimum = kind.minimumVersion.map(\.description) ?? ""
                Text(kind == .opencode
                    ? "现在是 \(version.description)。CuePad 只支持 OpenCode 2（v1 的服务接口不同）；装好 v2 后它替换 v1。"
                    : "现在是 \(version.description)，需要 \(minimum) 或更新。")
                    .foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Text("在终端运行：").foregroundStyle(palette.ink2)
            InstallCommand(kind: kind, presence: presence)
            Text("装好后回到这里接入。").foregroundStyle(palette.ink2)
            Link("了解 \(kind.name)", destination: Self.site(kind))
        }
    }

    private var title: LocalizedStringResource {
        if kind.upgrades(presence) { return "升级 \(kind.name)" }
        return kind == .opencode ? "安装 OpenCode 2" : "安装 \(kind.name)"
    }

    private static func site(_ kind: AgentKind) -> URL {
        switch kind {
        case .pi: URL(string: "https://pi.dev")!
        case .claudeCode: URL(string: "https://code.claude.com")!
        case .codex: URL(string: "https://developers.openai.com/codex")!
        case .opencode: URL(string: "https://opencode.ai/v2/docs")!
        }
    }
}

/// 装一家 Agent 的一行终端命令与"复制"（设置里的安装方法，给想自己装的人）：命令只在 `AgentKind.installCommand`，接入面板的"安装"跑的就是它。
struct InstallCommand: View {
    let kind: AgentKind
    let presence: AgentStatus.Presence
    @Environment(\.palette) private var palette
    @State private var copied = false

    var body: some View {
        let command = command
        HStack(spacing: 8) {
            // 命令要看得全：放不下就折行，不截断
            Text(command).font(Typography.meta.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(copied ? "已复制" : "复制") {
                Clipboard.copy(command)
                copied = true
            }
            .controlSize(.small)
            .accessibilityLabel(copied ? "已复制 \(kind.name) 的安装命令" : "复制 \(kind.name) 的安装命令")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(palette.fill, in: .rect(cornerRadius: 8))
    }

    private var command: String {
        kind.installCommand(presence)
    }
}
#endif
