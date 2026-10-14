#if os(macOS)
import CryptoKit
import CueStore
import Foundation

/// Codex 的钩子：条目写在 `<CODEX_HOME>/hooks.json`（`HookFile`），信任记在 `config.toml` 的 `[hooks.state]`（经 `codex app-server` 的 `config/batchWrite` 写）。
///
/// - Codex 只执行被信任的钩子：信任条目的键是"hooks.json 的真实路径:事件:组号:条目号"，值是条目内容的哈希。装时向 Codex 要
///   （`hooks/list` 给出键与哈希，`config/batchWrite` 写入，和 `/hooks` 里点信任同一条路）；查状态不起进程，按 Codex 的规则自己算
///   （`hook_hash`：事件名与只含这一条的组，转成键排好序的紧凑 JSON 取 SHA-256），与 `config.toml` 里的比——对不上（没信任、
///   用户删了排在前面的组使组号变了、Codex 改了算法）就是旧版，重装时重新信任。
/// - 卸载删掉 CuePad 的信任条目（`config/batchWrite` 对带引号的键写 null）；CuePad 建的 `[hooks]`、`[hooks.state]` 空了一并删掉，
///   装之前没有 `config.toml`、删完只剩空白的删掉文件（装之前的样子记在 `HookFile.Footprint.config`）。
struct CodexHooks: AgentHookConfig {
    let home: URL
    let locate: @Sendable () async -> ExecutableLocator
    /// 起 codex 时的基础环境（`AgentPaths.environment`），在它之上换掉配置目录与查找路径
    let environment: [String: String]
    let hooks: HookFile

    /// 全部 12 个事件；权限确认要等 CuePad 作答（远程的回答可能很久才来，超时后 Codex 当作钩子没给决定，回到终端里问），
    /// 会话结束与中断 Codex 最多给 3 秒，其余当场就回。
    static let events: [HookFile.Event] = [
        .init(name: "SessionStart", timeout: 10), .init(name: "UserPromptSubmit", timeout: 10), .init(name: "PreToolUse", timeout: 10),
        .init(name: "PermissionRequest", timeout: 86_400, statusMessage: waitingMessage), .init(name: "PostToolUse", timeout: 10),
        .init(name: "PreCompact", timeout: 10), .init(name: "PostCompact", timeout: 10), .init(name: "SubagentStart", timeout: 10),
        .init(name: "SubagentStop", timeout: 10), .init(name: "Stop", timeout: 10), .init(name: "Interrupt", timeout: 3),
        .init(name: "SessionEnd", timeout: 3),
    ]

    /// 权限确认的钩子挂住等 CuePad 时（人不在这台 Mac 前），Codex 终端里那一行显示它（钩子拿着这次确认，终端里不弹框）。
    static let waitingMessage = "等你在 CuePad 里确认"

    init(home: URL, skillDirectory: URL, locate: @escaping @Sendable () async -> ExecutableLocator, environment: [String: String]) {
        self.home = home
        self.locate = locate
        self.environment = environment
        hooks = HookFile(agent: .codex, file: home.appending(path: "hooks.json"), skillDirectory: skillDirectory, events: Self.events)
    }

    private var configFile: URL { home.appending(path: "config.toml") }
    var writtenFiles: [URL] { [hooks.file, configFile] }

    /// `config.toml` 装之前的样子：文件在不在；`[hooks]`、`[hooks.state]` 在不在（第一次写信任时才知道）。
    struct ConfigFootprint: Codable, Equatable {
        var file: Bool
        var hooksTable: Bool?
        var stateTable: Bool?
    }

    // MARK: 状态

    func files(command: String) -> AgentStatus.Files {
        let state = hooks.files(command: command)
        guard state == .current, let text = try? Data(contentsOf: hooks.file), let tree = try? JSONSourceTree(text) else { return state }
        let config = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let path = hooks.file.realPath.path
        let trusted = hooks.ourGroups(in: tree).allSatisfy { group in
            Self.events.first { $0.name == group.event }.map { event in
                Self.trustedHash(of: Self.key(path, event.name, group.index), in: config) == Self.hash(event, command: command, hooks: hooks)
            } ?? false
        }
        return trusted ? .current : .outdated
    }

    // MARK: 安装与卸载

    func install(command: String) async throws {
        if hooks.footprint()?.config == nil {
            var footprint = hooks.footprint() ?? HookFile.Footprint(file: FileManager.default.fileExists(atPath: hooks.file.path))
            footprint.config = ConfigFootprint(file: FileManager.default.fileExists(atPath: configFile.path))
            try hooks.save(footprint)
        }
        try hooks.install(command: command)
        try await trust(command: command)
        guard files(command: command) == .current else { throw CodexHooksError.notTrusted }
    }

    func uninstall() async throws {
        let footprint = hooks.footprint() ?? .unknown
        if let original = try? Data(contentsOf: hooks.file), let tree = try? JSONSourceTree(original) {
            let path = hooks.file.realPath.path
            let config = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
            let keys = hooks.ourGroups(in: tree).map { Self.key(path, $0.event, $0.index) }.filter { Self.trustedHash(of: $0, in: config) != nil }
            if !keys.isEmpty { try await untrust(keys, footprint: footprint.config) }
        }
        try hooks.uninstall()
    }

    /// 让 Codex 信任 CuePad 的条目：它列出的键与哈希原样写回。第一次写之前记下 `[hooks]`、`[hooks.state]` 原来在不在。
    private func trust(command: String) async throws {
        try await withCodex { rpc in
            let list = try await rpc.call("hooks/list", ["cwds": [home.path]])
            let listed = (list["data"] as? [CodexRPC.Object])?.first
            let entries = (listed?["hooks"] as? [CodexRPC.Object]) ?? []
            guard entries.contains(where: { $0["command"] as? String == command }) else {
                throw CodexHooksError.rejected(((listed?["warnings"] as? [String]) ?? []).joined(separator: "；"))
            }
            var state: CodexRPC.Object = [:]
            for entry in entries where entry["command"] as? String == command && entry["trustStatus"] as? String != "trusted" {
                guard let key = entry["key"] as? String, let hash = entry["currentHash"] as? String else { continue }
                state[key] = ["trusted_hash": hash]
            }
            guard !state.isEmpty else { return }
            if var footprint = hooks.footprint(), footprint.config?.stateTable == nil {
                let user = try await userHooks(rpc)
                footprint.config?.hooksTable = user == nil
                footprint.config?.stateTable = user?["state"] == nil
                try hooks.save(footprint)
            }
            try await rpc.call("config/batchWrite", ["edits": [["keyPath": "hooks.state", "value": state, "mergeStrategy": "upsert"]]])
        }
    }

    /// 删掉这些信任条目；CuePad 建的 `[hooks.state]` 因此空了就删掉它，CuePad 建的 `[hooks]` 也只剩它就一并删掉。
    /// 装之前没有 `config.toml`、删完只剩空白的，删掉文件。
    private func untrust(_ keys: [String], footprint: ConfigFootprint?) async throws {
        try await withCodex { rpc in
            let user = try await userHooks(rpc) ?? [:]
            let state = user["state"] as? CodexRPC.Object ?? [:]
            var edits: [CodexRPC.Object] = keys.map { ["keyPath": "hooks.state.\(Self.quoted($0))", "value": NSNull(), "mergeStrategy": "replace"] }
            if footprint?.stateTable == true, Set(state.keys).isSubset(of: keys) {
                edits.append(["keyPath": "hooks.state", "value": NSNull(), "mergeStrategy": "replace"])
                if footprint?.hooksTable == true, user.keys.allSatisfy({ $0 == "state" }) {
                    edits.append(["keyPath": "hooks", "value": NSNull(), "mergeStrategy": "replace"])
                }
            }
            try await rpc.call("config/batchWrite", ["edits": edits])
        }
        if footprint?.file == false, let left = try? String(contentsOf: configFile, encoding: .utf8), left.allSatisfy(\.isWhitespace) {
            try FileManager.default.removeItem(at: configFile)
        }
    }

    /// 用户层 `config.toml` 里的 `[hooks]`（不含别的层与缺省值）；没有为 nil。
    @MainActor private func userHooks(_ rpc: CodexRPC) async throws -> CodexRPC.Object? {
        let read = try await rpc.call("config/read", ["includeLayers": true])
        let user = (read["layers"] as? [CodexRPC.Object])?.first { ($0["name"] as? CodexRPC.Object)?["type"] as? String == "user" }
        return (user?["config"] as? CodexRPC.Object)?["hooks"] as? CodexRPC.Object
    }

    /// 起一个指向这个配置目录的 `codex app-server`，用完关掉并等它退出。
    private func withCodex(_ body: @MainActor (CodexRPC) async throws -> Void) async throws {
        let locator = await locate()
        guard let codex = locator.executable(.codex) else { throw CodexHooksError.codexNotFound }
        var environment = environment
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = locator.environment(launching: codex, overrides: self.environment)["PATH"]
        try await Self.run(codex, environment, body)
    }

    @MainActor private static func run(
        _ codex: URL, _ environment: [String: String], _ body: @MainActor (CodexRPC) async throws -> Void
    ) async throws {
        let rpc = try await CodexRPC.launch(codex, environment: environment)
        do {
            try await body(rpc)
        } catch {
            await rpc.shutdown()
            throw error
        }
        await rpc.shutdown()
    }

    // MARK: 信任条目

    /// Codex 的信任哈希（`hook_hash`）：条目按 Codex 读进来的样子补全（`async` 缺省 false）。
    static func hash(_ event: HookFile.Event, command: String, hooks: HookFile) -> String? {
        guard var handler = (hooks.group(event, command: command)["hooks"] as? [[String: Any]])?.first else { return nil }
        handler["async"] = false
        let identity: [String: Any] = ["event_name": label(event.name), "hooks": [handler]]
        guard let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Codex 内部的事件名：`PreToolUse` → `pre_tool_use`。
    static func label(_ event: String) -> String {
        event.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result.append("_") }
            result.append(character.lowercased())
        }
    }

    static func key(_ path: String, _ event: String, _ group: Int) -> String { "\(path):\(label(event)):\(group):0" }

    private static func quoted(_ key: String) -> String {
        "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `config.toml` 里这个键的 `trusted_hash`：Codex 写成 `[hooks.state."<键>"]` 一张表，下一行是 `trusted_hash = "…"`。
    static func trustedHash(of key: String, in config: String) -> String? {
        let header = "[hooks.state.\(quoted(key))]"
        var inTable = false
        for line in config.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                inTable = line == header
                continue
            }
            guard inTable, line.hasPrefix("trusted_hash"), let start = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), start < end
            else { continue }
            return String(line[line.index(after: start)..<end])
        }
        return nil
    }
}

enum CodexHooksError: Error, Equatable {
    case codexNotFound
    case notTrusted
    /// Codex 读不进 hooks.json（它的原话）
    case rejected(String)
}

extension CodexHooksError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .codexNotFound: "没有找到 codex 命令：Codex 的钩子要它来信任与撤销"
        case .notTrusted: "Codex 没有信任 CuePad 的钩子（它的信任规则可能变了），钩子不会执行"
        case .rejected(let reason): "Codex 读不了 hooks.json：\(reason)"
        }
    }
}
#endif
