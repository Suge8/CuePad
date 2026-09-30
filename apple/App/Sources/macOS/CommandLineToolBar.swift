#if os(macOS)
import SwiftUI

/// 设置窗口底部一行：把 `cuepad` 命令行工具装进 PATH（agent 在 bash 里直接调用）。
struct CommandLineToolBar: View {
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
            Text(detail).font(.caption).foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.vertical, 12)
        .task { await tool.refresh() }
    }

    private var canToggle: Bool {
        switch tool.state {
        case .unavailable, .blocked: false
        case .notInstalled, .installed, .stale: true
        }
    }

    private var warning: Bool {
        switch tool.state {
        case .stale, .blocked, .unavailable: true
        case .installed: tool.pathIncludesLinkDirectory == false
        case .notInstalled: false
        }
    }

    private var detail: String {
        let path = "~/.local/bin/cuepad"
        switch tool.state {
        case .unavailable: return "这个构建里没有命令行工具。"
        case .notInstalled: return "在 \(path) 建一个指向 App 内命令行工具的链接，不需要管理员权限。"
        case .stale: return "\(path) 指向的 CuePad 已不在原位置（App 被移动过），点“修复链接”指向当前位置。"
        case .blocked(let what): return "\(path) 位置\(what)，没有覆盖；确认不需要后请自行删除再安装。"
        case .installed:
            if tool.pathIncludesLinkDirectory == false {
                return "已安装，但 ~/.local/bin 不在你的 shell 的 PATH 里：在 shell 配置里加 export PATH=\"$HOME/.local/bin:$PATH\"。"
            }
            return "已安装：\(path)。"
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
