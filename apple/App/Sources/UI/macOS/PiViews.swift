#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

// MARK: Pi 状态

extension PiAgentState {
    /// 归到各端共用的那套状态：颜色、状态点、状态名都按它（Shared 的 `PiWorkState`），这里不另设一份。
    var work: Open<PiWorkState> { .known(syncRepresentation.state) }

    /// 状态名；工具调用多带上工具名。
    var label: String {
        guard case .tool(let name, let running, _) = self else { return work.label }
        return running.count > 1 ? "\(work.label) · \(name) 等 \(running.count) 个" : "\(work.label) · \(name)"
    }

    /// 此刻在做什么的一句话：工具调用摘要、弹窗标题或出错的人话摘要；旧扩展不带详情时为 nil，界面只显示状态。
    var detail: String? {
        if let summary = errorSummary { return summary.title }
        return fullDetail
    }

    /// 详情的全文（出错时是 Pi 上报的原文），给悬停提示。
    var fullDetail: String? {
        let text: String? = switch self {
        case .tool(_, _, let detail): detail
        case .waitingUser(_, let title): title
        case .error(let message): message
        default: nil
        }
        return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// 详情是命令或路径（工具调用）时用等宽字。
    var detailIsCode: Bool {
        if case .tool = self { true } else { false }
    }

    /// 需要用户过去看一眼。
    var needsAttention: Bool { work == .known(.waitingForUser) || work == .known(.error) }

    /// 状态文字的颜色：只有需要处理的才上色（颜色取共用的状态色）。
    func labelColor(_ palette: Palette) -> Color {
        needsAttention ? work.tint(palette) : palette.ink3
    }
}

/// 侧栏与菜单栏里一个会话的文字：主行是会话显示名，副行是所在（`PiPlace`：项目名或文件夹名）与状态（"CuePad · 思考中"）；
/// 需要处理时（出错、等你确认）副行接着写原因的开头，悬停看全文；否则有子代理时接着写子代理摘要。
struct PiSessionLabel: View {
    let session: CuePi.PiSession
    let project: Project?
    var nameFont: Font = .body
    var lineFont: Font = .caption
    @Environment(\.palette) private var palette

    var body: some View {
        let state = session.state
        VStack(alignment: .leading, spacing: 1) {
            Text(session.displayName).font(nameFont).lineLimit(1)
            PiActivityLine(
                lead: [PiPlace.name(project: project, folder: session.cwd.lastPathComponent, besides: session.displayName), state.label],
                detail: state.needsAttention ? state.detail : session.subagentSummary,
                font: lineFont, full: state.fullDetail)
                .foregroundStyle(state.labelColor(palette))
        }
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

/// 状态详情的一行文字；没有详情时不占位。
struct PiDetail: View {
    let state: PiAgentState
    var size: CGFloat = 12

    var body: some View {
        if state.detail != nil {
            PiActivityLine(detail: state.detail, detailIsCode: state.detailIsCode, font: .system(size: size), full: state.fullDetail)
                .foregroundStyle(.secondary)
        }
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
