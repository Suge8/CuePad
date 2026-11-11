#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

@MainActor
@Suite(RealAgents.needs(.codex))
struct CodexHooksTests {
    let codex: CodexHome
    var hooksFile: URL { codex.home.appending(path: "hooks.json") }
    var configFile: URL { codex.home.appending(path: "config.toml") }

    init() async throws { codex = try CodexHome(model: try await FakeModel()) }

    /// 旧版接入时写下的钩子（命令里的 cuepad 是 App 的旧位置，这里不跑钩子）连同 Codex 给它们的信任一起删掉，用户自己的钩子与信任留着。
    @Test func oldHooksAndTheirTrustAreRemovedAndTheUsersStay() async throws {
        try await codex.using {
            let userHooks = """
                {
                  "description": "我的钩子",
                  "hooks": {
                    "SessionStart": [ { "hooks": [ { "type": "command", "command": "echo hi", "timeout": 5 } ] } ],
                    "Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo bye"}]}]
                  }
                }

                """
            let ours = #",{"hooks":[{"command":"/Applications/CuePad.app/Contents/Helpers/cuepad hook codex","timeout":10,"type":"command"}]}"#
            let written = userHooks.replacingOccurrences(of: "\"timeout\": 5 } ] }", with: "\"timeout\": 5 } ] }" + ours)
                .replacingOccurrences(of: #""echo bye"}]}"#, with: #""echo bye"}]}"# + ours)
            try written.write(to: hooksFile, atomically: true, encoding: .utf8)
            try "model = \"gpt-6-luna\"  # 我的模型\n\n[tui]\nanimations = false\n".write(to: configFile, atomically: true, encoding: .utf8)
            try await codex.trustEverything()
            #expect(try await codex.hookTrust().map(\.trust) == ["trusted", "trusted", "trusted", "trusted"])

            let integration = AgentIntegration(paths: codex.paths, locate: { [codex] in codex.locator }, cuepad: URL(filePath: "/unused"), timing: noDeadline)
            try await integration.removeOldHooks(codex: codex.locator.candidates("codex").first)

            #expect(try String(contentsOf: hooksFile, encoding: .utf8) == userHooks)
            #expect(try await codex.hookTrust().map { "\($0.command) \($0.trust)" } == ["echo hi trusted", "echo bye trusted"])
            #expect(try String(contentsOf: configFile, encoding: .utf8).components(separatedBy: "[hooks.state.").count == 3)
        }
    }
}

extension CodexHome {
    @MainActor fileprivate func hookTrust() async throws -> [(command: String, event: String, trust: String)] {
        try await listedHooks().map { ($0["command"]?.string ?? "", $0["eventName"]?.string ?? "", $0["trustStatus"]?.string ?? "") }
    }

    @MainActor fileprivate func trustEverything() async throws {
        var state: [String: JSONValue] = [:]
        for entry in try await listedHooks() { state[entry["key"]!.string!] = ["trusted_hash": entry["currentHash"]!] }
        try await withCodex { try await $0.call("config/batchWrite", ["edits": [["keyPath": "hooks.state", "value": .object(state), "mergeStrategy": "upsert"]]]) }
    }

    @MainActor private func listedHooks() async throws -> [JSONValue] {
        var entries: [JSONValue] = []
        try await withCodex { rpc in
            let list = try await rpc.call("hooks/list", ["cwds": [.string(home.path)]])
            entries = list["data"]?.array?.first?["hooks"]?.array ?? []
        }
        return entries
    }

    @MainActor private func withCodex(_ body: (CodexRPC) async throws -> Void) async throws {
        let rpc = try await CodexRPC.launch(pinnedCodex.executable, environment: environment)
        do {
            try await body(rpc)
        } catch {
            await rpc.shutdown()
            throw error
        }
        await rpc.shutdown()
    }
}
#endif
