#if os(macOS)
import Foundation

/// Claude Code 的钩子：CuePad 的条目写在 `<配置目录>/settings.json` 的 `hooks` 键里。
struct ClaudeCodeHooks: AgentHookConfig {
    let home: URL

    func files(command: String) -> AgentStatus.Files { .missing }  // TODO

    func install(command: String) async throws {}  // TODO

    func uninstall() async throws {}  // TODO
}
#endif
