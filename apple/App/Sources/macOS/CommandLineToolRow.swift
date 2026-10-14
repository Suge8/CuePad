#if os(macOS)
import SwiftUI

/// 设置里"cuepad 命令"那一行：把命令行工具链接进 PATH（Agent 在终端里直接调用）。开着时状态写链接的位置；
/// 链接失效给"修复"，链接目录不在 PATH 里给"复制命令"（加进 shell 配置的那一行），位置被别的文件占着时说明、不覆盖。
struct CommandLineToolRow: View {
    @Environment(AppServices.self) private var services
    @State private var error: String?
    @State private var copied = false

    private var tool: CommandLineToolInstaller { services.commandLineTool }

    var body: some View {
        let (tone, status) = describe
        SettingRow(
            title: "cuepad 命令", symbol: "terminal", tone: tone, status: status,
            help: "在 \(tool.linkDirectoryDisplay) 建一个指向 App 内命令行工具的 cuepad 链接，不需要管理员权限"
        ) {
            Toggle("cuepad 命令", isOn: Binding(get: { tool.state == .installed }, set: { apply($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!canToggle)
        } fix: {
            if error == nil {
                if tool.state == .stale {
                    Button("修复") { apply(true) }.settingFix()
                } else if tool.state == .installed, tool.pathIncludesLinkDirectory == false {
                    Button(copied ? "已复制" : "复制命令") {
                        Clipboard.copy(tool.pathExport)
                        copied = true
                    }
                    .settingFix()
                    .help("把这一行加进 shell 配置：\(tool.pathExport)")
                }
            }
        }
        .task { await tool.refresh() }
    }

    private var canToggle: Bool {
        switch tool.state {
        case .unavailable, .blocked: false
        case .notInstalled, .installed, .stale: true
        }
    }

    /// 读不出 PATH 也要明说，不静默。
    private var describe: (SettingTone, Dotted?) {
        if let error { return (.failure, Dotted(error)) }
        switch tool.state {
        case .notInstalled: return (.calm, nil)
        case .unavailable: return (.calm, "这个构建里没有命令行工具")
        case .stale: return (.attention, "App 移动过，链接失效了")
        case .blocked(let what): return (.failure, "\(tool.linkDirectoryDisplay)/cuepad 位置\(what)，没有覆盖")
        case .installed:
            return switch tool.pathIncludesLinkDirectory {
            case true?: (.calm, "\(tool.linkDirectoryDisplay)/cuepad")
            case false?: (.attention, "\(tool.linkDirectoryDisplay) 不在 PATH 里")
            case nil: (.attention, "没能读取 shell 的 PATH，请确认 \(tool.linkDirectoryDisplay) 在其中")
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
