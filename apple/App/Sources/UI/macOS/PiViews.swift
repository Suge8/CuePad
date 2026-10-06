#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

// MARK: Pi 状态

extension PiAgentState {
    /// 归到各端共用的那套状态：颜色、状态标、状态名都按它（Shared 的 `PiWorkState`），这里不另设一份。
    var work: Open<PiWorkState> { .known(syncRepresentation.state) }

    /// 出错时 Pi 上报的原文（会话行悬停看）；行上写的是摘要。
    var errorMessage: String? {
        if case .error(let message) = self { message } else { nil }
    }
}

/// Mac 上一个 Pi 会话的行（侧栏、菜单栏面板、项目页的 Pi 栏），三层与 iOS 的 Agent 页一致：状态标；名字与时长（`PiElapsed`）；
/// 在哪 · 状态词（带色）；一句进度或结果（`PiProgress`，没有不占行）。已结束的整行更淡。
struct PiSessionRow: View {
    let session: PiSessionState
    let project: Project?
    var nameFont: Font = .body
    var lineFont: Font = .caption
    var dotSize: CGFloat = 6
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PiStateDot(state: session.state, size: dotSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title).font(nameFont).foregroundStyle(palette.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    PiElapsed(session: session, font: lineFont)
                }
                HStack(spacing: 3) {
                    if let place = PiPlace.name(of: session, project: project) {
                        Text("\(place) ·").foregroundStyle(palette.ink3).lineLimit(1)
                    }
                    Text(session.state.label).fontWeight(.medium).foregroundStyle(session.state.tint(palette))
                    if session.hosted { Text("· 后台").foregroundStyle(palette.ink3) }
                }
                .font(lineFont)
                if let progress = PiProgress.line(of: session) {
                    Text(progress).font(lineFont).foregroundStyle(palette.ink2).lineLimit(1)
                }
            }
        }
        .opacity(session.state == .known(.ended) ? 0.6 : 1)
        .accessibilityElement(children: .combine)
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
            if showsTitle { Text(missing ? "安装 Pi" : "升级 Pi").font(.headline) }
            Text("Pi 是在终端里运行的 AI 编程助手。装好后，卡片可以直接发进 Pi 会话。")
                .fixedSize(horizontal: false, vertical: true)
            if case .found(_, let version) = installation {
                Text("现在是 \(version)，需要 \(PiVersion.minimumSupported) 或更新。").foregroundStyle(.secondary)
            }
            Text(missing ? "在终端运行：" : "在终端运行，升级到最新版：").foregroundStyle(.secondary)
            HStack(spacing: 8) {
                // 命令要看得全：放不下就折行，不截断
                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(copied ? "已复制" : "复制") { copy(command) }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            Link("了解 Pi", destination: Self.site)
        }
        .font(.system(size: 13))
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
    }
}

#endif
