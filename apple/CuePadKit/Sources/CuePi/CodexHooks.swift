#if os(macOS)
import Foundation

/// Codex 的钩子：CuePad 的条目写在 `<CODEX_HOME>/hooks.json`，信任记在 `config.toml` 的 `[hooks.state]`（经 `codex app-server` 的 `config/batchWrite` 写）。
struct CodexHooks: AgentHookConfig {
    let home: URL
    let locator: ExecutableLocator

    func files(command: String) -> AgentStatus.Files { .missing }  // TODO

    func install(command: String) async throws {}  // TODO

    func uninstall() async throws {}  // TODO
}
#endif
