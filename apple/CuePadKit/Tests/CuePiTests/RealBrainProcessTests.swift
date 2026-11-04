#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 连真运行时才看得出的（进程树、各家的历史）：录制时列出的、OpenCode（总连真的），本机跑得起来的几家
private let liveRuntimes = AgentKind.allCases.filter { RealAgents.runs($0) && RealAgents.mode(of: $0) != .replay }
private let home = FileManager.default.homeDirectoryForCurrentUser

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
        // OpenCode 的会话在它的库里：用接入连的后台服务看这个工作目录里的会话，停之前有、停之后一个不剩
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
            #expect(try codexSessions(mentioning: rig.marker) == [])
        case .claudeCode:
            #expect(try claudeTranscripts(for: rig.marker) == [])
        case .opencode:
            let sandbox = try #require(sandbox)
            let left = try await openCodeSessions(in: rig.directory, sandbox)
            try await sandbox.stop()
            #expect(left.isEmpty, "\(left)")
        case .grok:
            // 大脑的配置目录是它自己的临时目录（停下时删掉）：用户的会话目录里没有这个工作目录（只读）
            let sessions = home.appending(path: ".grok/sessions")
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

    /// Codex 的会话文件（只读）里提到这个工作目录的。
    private func codexSessions(mentioning marker: String) throws -> [String] {
        let root = home.appending(path: ".codex/sessions")
        let recent = Date().addingTimeInterval(-600)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?.compactMap { $0 as? URL } ?? []
        return files.filter { file in
            guard file.pathExtension == "jsonl", let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified > recent, let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return text.contains(marker)
        }.map(\.path)
    }

    /// Claude Code 按工作目录存的会话记录（只读）。
    private func claudeTranscripts(for marker: String) throws -> [String] {
        let root = home.appending(path: ".claude/projects")
        let projects = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(marker) }
        return projects.flatMap { project in
            ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: project).path)) ?? []).filter { $0.hasSuffix(".jsonl") }
        }
    }
}
#endif
