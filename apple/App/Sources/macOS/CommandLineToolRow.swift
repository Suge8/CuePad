#if os(macOS)
import SwiftUI

/// 设置里"命令行"一节的一行：把 `cuepad` 命令行工具装进 PATH（agent 在 bash 里直接调用）。
struct CommandLineToolRow: View {
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @State private var error: String?

    private var tool: CommandLineToolInstaller { services.commandLineTool }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("在终端里使用 cuepad 命令", isOn: Binding(get: { tool.state == .installed }, set: { apply($0) }))
                    .disabled(!canToggle)
                Spacer()
                if tool.state == .stale { Button("修复链接") { apply(true) } }
            }
            let detail = Self.detail(state: tool.state, pathIncludesLinkDirectory: tool.pathIncludesLinkDirectory)
            Text(detail.text).font(Typography.meta).foregroundStyle(detail.isWarning ? AnyShapeStyle(palette.attention) : AnyShapeStyle(.secondary))
            if let error { Text(error).font(Typography.meta).foregroundStyle(palette.attention) }
        }
        .task { await tool.refresh() }
    }

    private var canToggle: Bool {
        switch tool.state {
        case .unavailable, .blocked: false
        case .notInstalled, .installed, .stale: true
        }
    }

    /// 状态说明；`isWarning` 时用醒目颜色。已安装但链接目录可能不在 PATH 里（含读不出 PATH）都要明说，不静默。
    static func detail(state: CommandLineToolInstaller.State, pathIncludesLinkDirectory: Bool?) -> (text: String, isWarning: Bool) {
        let path = "~/.local/bin/cuepad"
        switch state {
        case .unavailable: return ("这个构建里没有命令行工具。", true)
        case .notInstalled: return ("在 \(path) 建一个指向 App 内命令行工具的链接，不需要管理员权限。", false)
        case .stale: return ("\(path) 指向的 CuePad 已不在原位置（App 被移动过），点“修复链接”指向当前位置。", true)
        case .blocked(let what): return ("\(path) 位置\(what)，没有覆盖；确认不需要后请自行删除再安装。", true)
        case .installed:
            switch pathIncludesLinkDirectory {
            case true?: return ("已安装：\(path)。", false)
            case false?:
                return ("已安装，但 ~/.local/bin 不在你的 shell 的 PATH 里：在 shell 配置里加 export PATH=\"$HOME/.local/bin:$PATH\"。", true)
            case nil: return ("已安装，但没能读取你的 shell PATH，请确认 ~/.local/bin 在 PATH 中。", true)
            }
        }
    }

    private func apply(_ install: Bool) {
        error = nil
        Task {
            do {
                if install { try await tool.install() } else { try await tool.uninstall() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
