#if os(macOS)
import AppKit
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import CuePad

private let output = URL(filePath: ProcessInfo.processInfo.environment["CUEPAD_CUE_EVAL_OUT"] ?? "/tmp/cue-eval/latest", directoryHint: .isDirectory)

/// 一条判定：用户看得到的一项行为。
struct Check {
    let label: String
    let passed: Bool
    init(_ label: String, _ passed: Bool) {
        self.label = label
        self.passed = passed
    }
}

/// 一件 Cue 开过工、正在做的任务：开工时送进会话的第一句记在发送记录里（会话里那句因此认作 Cue 说的，不是"他说的"），
/// 会话是本机开着的假扩展（Cue 对它说话、作答都送得到）。
struct Working {
    let task: Card
    let session: FakeExtension
    let prompt: PiChatMessage
    var id: String { session.sessionID }
}

/// 一个场景的现场：Rig、叫醒 Cue 的时刻，以及被叫醒的那一轮。
@MainActor
final class CueEval {
    let rig: CueHostTests.Rig
    private var start = Date.distantFuture

    private init(_ rig: CueHostTests.Rig) { self.rig = rig }

    /// 起 Rig、等刚启用那一轮做完，跑 `body`（摆状态、叫醒、判定）；不论成败都把现场写完、停掉大脑，再报没过的判定。
    static func run(_ name: String, expect: String, _ body: (CueEval) async throws -> [Check]) async throws {
        let eval = CueEval(try await CueHostTests.Rig(claude: .current))
        var checks: [Check] = [], failure: (any Error)?
        do {
            try await eventually("刚启用那一轮做完", timeout: .seconds(300)) { eval.rig.rounds.contains { $0.wake == .enabled && $0.finishedAt != nil } }
            checks = try await body(eval)
            checks.append(try await eval.showsNoIDs())
        } catch {
            failure = error
        }
        await eval.write(name, expect: expect, checks: checks, failure: failure)
        await eval.rig.stop()
        #expect(eval.rig.brainPIDs.isEmpty, "大脑停掉了")
        for check in checks where !check.passed { Issue.record("\(name)：\(check.label)") }
        if let failure { throw failure }
    }

    /// 叫醒 Cue（你说一句，或会话有动静），等被叫醒的那一轮做完。
    func trigger(_ wake: () async throws -> Void) async throws {
        start = .now
        try await wake()
        try await eventually("Cue 做完被叫醒的那一轮", timeout: .seconds(420)) { self.round?.finishedAt != nil }
    }

    /// 被叫醒的那一轮
    var round: CueRound? { rig.rounds.first { $0.startedAt >= start } }

    /// 那一轮里调的 `tool`（只看 `action` 这一种）与它的参数
    func calls(_ tool: String, _ action: String? = nil) -> [(call: CueToolCall, args: [String: Any])] {
        (round?.calls ?? []).compactMap { call in
            let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
            guard call.name == tool, action == nil || args["action"] as? String == action else { return nil }
            return (call, args)
        }
    }

    /// 叫醒之后 Cue 写的消息（tell、回复、动态、完成的结果）
    func said() async throws -> [CueMessage] {
        try await rig.store.cueMessages().filter { $0.createdAt >= start && $0.author != .known(.you) && !$0.text.isEmpty }
    }

    /// 他看得到的字（消息与记下的记忆）没抄信封、工具结果里括号中的编号：每个场景都判。
    func showsNoIDs() async throws -> Check {
        let seen = rig.rounds.filter { $0.startedAt >= start }.flatMap { $0.sent + $0.calls.compactMap(\.result) }
        let ids = Set(seen.flatMap { $0.matches(of: /（((?:s-)?[0-9a-f]{6,8})）/).map { String($0.1) } })
        let written = try await said().map(\.text) + calls("memory", "note").compactMap { $0.args["text"] as? String }
        return Check("他看得到的字里没有编号", !written.contains { text in ids.contains { text.contains($0) } })
    }

    /// 回答你的那句
    func reply() async throws -> CueMessage? { try await said().last { $0.author == .known(.cue) && $0.choices == nil && $0.taskID == nil } }

    private func write(_ name: String, expect: String, checks: [Check], failure: (any Error)?) async {
        let passed = failure == nil && !checks.isEmpty && checks.allSatisfy(\.passed)
        let verdict = failure != nil ? "出错" : passed ? "通过" : "不通过"
        let round = round
        let elapsed = round?.finishedAt.map { seconds($0.timeIntervalSince(round!.startedAt)) } ?? "—"
        let context = round?.context.map(String.init) ?? "—"
        var lines = [
            "<!-- row: | \(name) | \(verdict) | \(round?.calls.count ?? 0) | \(elapsed) | \(context) | -->",
            "# \(name)", "", "期望：\(expect)", "", "模型：\(ClaudeCue.current.model) · \(ClaudeCue.current.effort.rawValue)", "",
            "## 判定：\(verdict)", "",
        ]
        lines += checks.map { "- [\($0.passed ? "x" : " ")] \($0.label)" }
        if let failure { lines += ["", "出错：\(failure)"] }
        lines += ["", "## 用时与上下文", "", "- 被叫醒的这一轮：\(elapsed)，结束时上下文 \(context) token"]
        if let greeting = rig.rounds.first(where: { $0.wake == .enabled }) {
            let took = greeting.finishedAt.map { seconds($0.timeIntervalSince(greeting.startedAt)) } ?? "没做完"
            lines.append("- 刚启用那一轮（预热，不评）：\(took)，上下文 \(greeting.context.map(String.init) ?? "—")，工具 \(greeting.calls.map(\.name).joined(separator: "、"))")
        }
        for (index, round) in rig.rounds.filter({ $0.startedAt >= start }).enumerated() {
            lines += ["", "## 第 \(index + 1) 轮（醒来：\(round.wake)）\(round.finishedAt == nil ? "（写下时还没做完）" : "")", "", "### 发给大脑的"]
            lines += round.sent.flatMap { ["", "```text", $0, "```"] }
            lines += ["", "### 工具调用（\(round.calls.count)）"]
            for (number, call) in round.calls.enumerated() {
                let took = call.finishedAt.map { seconds($0.timeIntervalSince(call.startedAt)) } ?? "没做完"
                lines += ["", "\(number + 1). `\(call.name)` · \(took)\(call.failed ? " · 出错" : "")", "", "```json", call.arguments, "```", "", "```text", call.result ?? "", "```"]
            }
            if let failed = round.failure { lines += ["", "这一轮出错：\(failed)"] }
        }
        lines += ["", "## Cue 写的消息"]
        for message in (try? await said()) ?? [] {
            var head = "- **\(message.author.rawValue)**"
            if let choices = message.choices { head += "（等你：\(choices.joined(separator: " / "))）" }
            if message.taskID != nil { head += "（关联任务）" }
            lines += ["", head, "", message.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  > \($0)" }.joined(separator: "\n")]
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").appending("\n").write(to: output.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
            // 资料库留一份，看这一场在 Cue 页上的样子（docs/verify.md「Cue 评测」）
            let library = output.appending(path: "\(name).library", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: library)
            try FileManager.default.copyItem(at: rig.app.databaseURL.deletingLastPathComponent(), to: library)
            let prompt = CuePrompt.system(name: CueProfile.defaultName, memory: CueMemoryView(try await rig.store.cueMemory()), agents: [])
            try Self.summarize(prompt: prompt)
        } catch {
            Issue.record("评测输出没写成：\(error)")
        }
    }

    /// 汇总目录里各场景的那一行，写 summary.md 与这次的系统提示；并行的场景（可能在别的进程里）按文件锁轮流写。
    private static func summarize(prompt: String) throws {
        let lock = open(output.appending(path: ".lock").path, O_CREAT | O_RDWR, 0o644)
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN); close(lock) }
        try prompt.write(to: output.appending(path: "system-prompt.md"), atomically: true, encoding: .utf8)
        let rows = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && !["summary", "system-prompt"].contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8).firstMatch(of: /<!-- row: (.*) -->/)?.1 }
        let wide = prompt.unicodeScalars.count { !$0.isASCII }, ascii = prompt.unicodeScalars.count { $0.isASCII }
        let summary = [
            "# Cue 评测", "", "模型：\(ClaudeCue.current.model) · \(ClaudeCue.current.effort.rawValue)", "",
            "系统提示 \(prompt.count) 字，估算 ≈\(wide + ascii / 4) token（非 ASCII 每字算 1、ASCII 每 4 字符算 1；工具说明另算）", "",
            "| 场景 | 判定 | 工具调用 | 用时 | 结束时上下文 token |", "| --- | --- | --- | --- | --- |",
        ] + rows.map(String.init)
        try summary.joined(separator: "\n").appending("\n").write(to: output.appending(path: "summary.md"), atomically: true, encoding: .utf8)
    }
}

private func seconds(_ interval: TimeInterval) -> String { String(format: "%.1fs", interval) }
#endif
