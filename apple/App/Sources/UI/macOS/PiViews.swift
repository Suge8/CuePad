#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

// MARK: Pi 状态

extension PiAgentState {
    /// 出错时 Pi 上报的原文（会话行悬停看）；行上写的是摘要。
    var errorMessage: String? {
        if case .error(let message) = self { message } else { nil }
    }
}

/// 没装 Pi 或版本太低时的说明（侧栏 Pi 分组的引导行点开、设置的 Pi 一节）：Pi 是什么、一行可复制的命令（没装是安装命令，
/// 版本太低是 Pi 自带的升级命令）、官网。
struct PiSetupGuide: View {
    let installation: PiInstallation
    /// 设置里已经有"Pi"小节标题，不再写标题
    var showsTitle = true
    @State private var copied = false

    /// 官方安装脚本（macOS 与 Linux，见 Pi 的 README）。
    static let installCommand = "curl -fsSL https://pi.dev/install.sh | sh"
    /// Pi 自带的升级命令。
    static let updateCommand = "pi update --self"
    static let site = URL(string: "https://pi.dev")!

    var body: some View {
        let missing = installation == .notFound
        let command = missing ? Self.installCommand : Self.updateCommand
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle { Text(missing ? "安装 Pi" : "升级 Pi").font(Typography.bodyStrong) }
            Text("Pi 是在终端里运行的 AI 编程助手。装好后，灵感和任务可以直接发进 Pi 会话。")
                .fixedSize(horizontal: false, vertical: true)
            if case .found(_, let version) = installation {
                Text("现在是 \(version)，需要 \(PiVersion.minimumSupported) 或更新。").foregroundStyle(.secondary)
            }
            Text(missing ? "在终端运行：" : "在终端运行，升级到最新版：").foregroundStyle(.secondary)
            HStack(spacing: 8) {
                // 命令要看得全：放不下就折行，不截断
                Text(command).font(Typography.meta.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(copied ? "已复制" : "复制") { copy(command) }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            Link("了解 Pi", destination: Self.site)
        }
        .font(Typography.secondary)
    }

    private func copy(_ command: String) {
        Clipboard.copy(command)
        copied = true
    }
}

/// 键帽：快捷键在界面上只有这一种写法（设置的快捷键一节、⌘K 面板的 esc）。
struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.keycap)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
    }
}

#endif
