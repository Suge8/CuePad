#if os(macOS)
import CueStore
import Foundation

/// 迁移代码（#202，见 `AgentIntegration.removeOldHooks`）：旧版写进 `hooks.json` 的钩子与它在 `config.toml` 里的信任。
/// 信任条目的键是“hooks.json 的真实路径:事件:组号:条目号”，所以先按 `hooks.json` 里 CuePad 的组算出键、删掉信任，再删组：
/// 先删了组就再也认不出哪些信任是 CuePad 的。删信任经 Codex 自己（`config/batchWrite`，和 `/hooks` 里撤销信任同一条路）。
struct CodexHooks {
    let home: URL
    /// 删信任时起的 `codex`（检测时挑中的那个）
    let codex: URL?
    let locate: @Sendable () async -> ExecutableLocator
    let environment: [String: String]
    let hooks: HookFile

    init(
        home: URL, skillDirectory: URL, codex: URL?, locate: @escaping @Sendable () async -> ExecutableLocator, environment: [String: String]
    ) {
        self.home = home
        self.codex = codex
        self.locate = locate
        self.environment = environment
        hooks = HookFile(agent: .codex, file: home.appending(path: "hooks.json"), skillDirectory: skillDirectory)
    }

    private var configFile: URL { home.appending(path: "config.toml") }

    /// 第一次写信任时才知道。
    struct ConfigFootprint: Codable, Equatable {
        var file: Bool
        var hooksTable: Bool?
        var stateTable: Bool?
    }

    /// 有信任要删而没有 `codex` 时什么都不动，留到下次。
    func remove() async throws {
        let keys = trustedKeys()
        if !keys.isEmpty {
            guard let codex else { return }
            try await untrust(keys, footprint: hooks.footprint()?.config, codex: codex)
        }
        try hooks.remove()
    }

    private func trustedKeys() -> [String] {
        guard let original = try? Data(contentsOf: hooks.file), let tree = try? JSONSourceTree(original) else { return [] }
        let path = hooks.file.realPath.path
        let config = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        return hooks.ourGroups(in: tree).map { Self.key(path, $0.event, $0.index) }.filter { Self.trustedHash(of: $0, in: config) != nil }
    }

    /// 删掉这些信任条目（`config/batchWrite` 对带引号的键写 null）；CuePad 建的 `[hooks.state]` 因此空了就删掉它，CuePad 建的 `[hooks]` 也只剩它就一并删掉。
    /// 装之前没有 `config.toml`、删完只剩空白的，删掉文件。
    private func untrust(_ keys: [String], footprint: ConfigFootprint?, codex: URL) async throws {
        let locator = await locate()
        var environment = environment
        environment[CodexRuntime.facts.homeVariable] = home.path
        environment["PATH"] = locator.environment(launching: codex, overrides: self.environment)["PATH"]
        try await Self.untrust(keys, footprint: footprint, codex: codex, environment: environment)
        if footprint?.file == false, let left = try? String(contentsOf: configFile, encoding: .utf8), left.allSatisfy(\.isWhitespace) {
            try FileManager.default.removeItem(at: configFile)
        }
    }

    @MainActor private static func untrust(_ keys: [String], footprint: ConfigFootprint?, codex: URL, environment: [String: String]) async throws {
        let rpc = try await CodexRPC.launch(codex, environment: environment)
        try await withStopped(rpc, stop: { await $0.shutdown() }) { rpc in
            let read = try await rpc.call("config/read", ["includeLayers": true])
            let user = read["layers"]?.array?.first { $0["name"]?["type"]?.string == "user" }?["config"]?["hooks"]?.object ?? [:]
            let state = user["state"]?.object ?? [:]
            var edits: [JSONValue] = keys.map { ["keyPath": .string("hooks.state.\(quoted($0))"), "value": .null, "mergeStrategy": "replace"] }
            if footprint?.stateTable == true, Set(state.keys).isSubset(of: keys) {
                edits.append(["keyPath": "hooks.state", "value": .null, "mergeStrategy": "replace"])
                if footprint?.hooksTable == true, user.keys.allSatisfy({ $0 == "state" }) {
                    edits.append(["keyPath": "hooks", "value": .null, "mergeStrategy": "replace"])
                }
            }
            try await rpc.call("config/batchWrite", ["edits": .array(edits)])
        }
    }

    private static func label(_ event: String) -> String {
        event.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result.append("_") }
            result.append(character.lowercased())
        }
    }

    private static func key(_ path: String, _ event: String, _ group: Int) -> String { "\(path):\(label(event)):\(group):0" }

    private static func quoted(_ key: String) -> String {
        "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `config.toml` 里这个键的 `trusted_hash`：Codex 写成 `[hooks.state."<键>"]` 一张表，下一行是 `trusted_hash = "…"`。
    private static func trustedHash(of key: String, in config: String) -> String? {
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
#endif
