#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

private let liveRuntimes = AgentKind.allCases.filter { RealAgents.runs($0) && RealAgents.mode(of: $0) != .replay }

/// 结束后进程连同它起的子进程（MCP 服务等）都退出、各家的历史里没有这次对话：断言的是真进程树与各家真实的历史目录，回放不出来，
/// 只在录制或直连时连真运行时跑。
@MainActor
@Suite(.enabled(if: !liveRuntimes.isEmpty, "只连真运行时跑（看真进程树与各家的历史）：CUEPAD_AGENT_TESTS 列出 pi、codex、claude、grok、dsh，或本机有 opencode v2 时开启"), .serialized, .timeLimit(.minutes(5)))
struct RealBrainProcessTests {
    @Test(arguments: liveRuntimes) func stoppingLeavesNoProcessesOrHistory(_ runtime: AgentKind) async throws {
        let rig = try await RealBrainTests.Rig(runtime)
        try await rig.brain.send("Reply with the single word OK.")
        try await rig.finished()

        let tree = try processTree(containing: rig.marker)
        #expect(tree.count >= 2)  // 运行时与 MCP 替身
        let sandbox = rig.sandbox
        if let sandbox {
            try await sandbox.run(["service", "start"])
            #expect(try await openCodeSessions(in: rig.directory, sandbox).count == 1)
        }
        await rig.brain.stop()()
        try await eventually("报告退出") { rig.events.last == .exited(nil) }
        let survivors = tree.filter { kill($0, 0) == 0 }
        #expect(survivors == [], "没退出的进程：\(survivors)")

        switch runtime {
        case .pi:
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.sessions.path)) ?? []) == [])
        case .codex:
            // CODEX_HOME 是这次运行的临时目录（`RealBrainTests.Rig`），会话不落进真实的 ~/.codex
            #expect(codexSessions(mentioning: rig.marker, in: rig.directory.deletingLastPathComponent().appending(path: "codex/sessions")) == [])
        case .claudeCode:
            // 用户的配置目录（`CLAUDE_CONFIG_DIR`）是测试台的隔离目录（`ClaudeSandbox.environment`）：会话没落进去，目录可能都没有
            #expect(claudeTranscripts(for: rig.marker, in: rig.directory.deletingLastPathComponent().appending(path: "config/projects")) == [])
        case .opencode:
            let sandbox = try #require(sandbox)
            let left = try await openCodeSessions(in: rig.directory, sandbox)
            try await sandbox.stop()
            #expect(left.isEmpty, "\(left)")
        case .grok:
            // 大脑的配置目录是它自己的临时目录（`RealBrainTests.Rig`），会话不落进真实的 ~/.grok
            let sessions = rig.directory.deletingLastPathComponent().appending(path: "grok-user/sessions")
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).filter { $0.contains(rig.marker) } == [])
        case .dsh:
            // 会话、附件、存储都在本次运行的临时目录里，随它删掉；dsh 的家目录里没有会话
            let dshHome = rig.directory.deletingLastPathComponent().appending(path: "dsh")
            #expect(!FileManager.default.fileExists(atPath: dshHome.appending(path: DshRuntime.sessions).path))
        }
    }

    private func openCodeSessions(in directory: URL, _ sandbox: OpenCodeSandbox) async throws -> [Any] {
        try await sandbox.api("GET", "/api/session?directory=" + OpenCodeClient.escaped(directory.path))["data"] as? [Any] ?? []
    }

    /// 大脑进程与它的全部后代：从命令行里带着标记的 MCP 替身往上找到运行时，再取它的整棵子树。运行时挂在 launchd 下
    /// （`ChildProcess` 经中转起，见它的头注释），挂在本测试进程下的也认。
    private func processTree(containing marker: String) throws -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(filePath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        let exit = try ProcessExit(launching: ps)
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        _ = exit.blockingValue
        let rows = text.split(separator: "\n").compactMap { line -> (pid: pid_t, ppid: pid_t, command: String)? in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { return nil }
            return (pid, ppid, String(parts[2]))
        }
        let parent = Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var root = try #require(rows.first { $0.command.contains(marker) }).pid
        while let up = parent[root], up != getpid(), up > 1 { root = up }
        var tree = [root]
        var index = 0
        while index < tree.count {
            tree += rows.filter { $0.ppid == tree[index] }.map(\.pid)
            index += 1
        }
        return tree
    }

    private func codexSessions(mentioning marker: String, in root: URL) -> [String] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "jsonl" && ((try? String(contentsOf: $0, encoding: .utf8))?.contains(marker) ?? false) }.map(\.path)
    }

    private func claudeTranscripts(for marker: String, in root: URL) -> [String] {
        let projects = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.contains(marker) }
        return projects.flatMap { project in
            ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: project).path)) ?? []).filter { $0.hasSuffix(".jsonl") }
        }
    }
}
#endif
