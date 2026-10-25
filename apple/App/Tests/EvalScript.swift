#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 剧本的骨架：叫醒、接手 Cue 开出的会话、读每一步里的工具调用与回复。长程（`Duty`）与多日（`CueEvalDaysTests`）的剧本都从它派生。
@MainActor
class EvalScript {
    let eval: CueEval
    var rig: CueHostTests.Rig { eval.rig }
    var sessions: [ScriptedSession] = []
    var steps: [Step] = []
    /// 剧本没按预想走的地方（Cue 没开工评测替它开、没叫醒）
    var notes: [String] = []

    /// 剧本的一步：叫醒的事、这次醒来的时段（没叫醒为 nil）、事出在哪个会话
    struct Step {
        let label: String
        let window: ClosedRange<Date>?
        let session: ScriptedSession?
    }

    init(_ eval: CueEval) { self.eval = eval }

    // MARK: 剧本的动作

    /// 他对 Cue 说一句，等 Cue 做完这次醒来引起的。
    @discardableResult
    func say(_ label: String, _ text: String) async throws -> Step {
        try await step(label, on: nil) { try await self.rig.say(text) }
    }

    /// 会话有动静，等 Cue 做完这次醒来引起的。
    @discardableResult
    func event(_ label: String, on session: ScriptedSession, _ act: () async throws -> Void) async throws -> Step {
        try await step(label, on: session, act)
    }

    func step(_ label: String, on session: ScriptedSession?, _ act: () async throws -> Void) async throws -> Step {
        let window = try await eval.settle(act)
        if window == nil { notes.append("「\(label)」没叫醒 Cue") }
        let step = Step(label: label, window: window, session: session)
        steps.append(step)
        return step
    }

    /// 他交代的事开出的会话：Cue 开工时执行器开出假扩展（new-<令牌>），开场白的发送记录把任务绑上它。
    /// Cue 这一步没开工（先对齐、没建）就由评测替它开，记一笔：后面的剧本要有这个会话。
    func adopt(_ topic: Regex<Substring>, after step: Step, title: String, in projectName: String) async throws -> ScriptedSession {
        let started = calls(step, "task", ["start"]).contains { !$0.call.failed }
        var found: ScriptedSession?
        if started {
            try? await eventually("Cue 开出的会话绑上任务") {
                found = try await self.opened(topic)
                return found != nil
            }
        } else {
            found = try? await opened(topic)
        }
        if let found {
            sessions.append(found)
            return found
        }
        notes.append("「\(title)」Cue 没开工，评测替它开了会话")
        let project = try #require(try await rig.store.projects().first { $0.name == projectName })
        var card = try await rig.store.cueBoard().tasks.map(\.task).last { task in step.window.map { $0.contains(task.createdAt) } == true && task.body.contains(topic) }
        if card == nil { card = try await rig.store.createTask("\(title)\n照他的话做，做完把证据发到手机。", in: project.id) }
        let task = try #require(card)
        let folder = try #require(try await rig.store.directory(of: project.id))
        let id = "s-\(UUID().uuidString.prefix(8).lowercased())", delivery = UUID()
        try await rig.store.recordSend(task.body, to: SendTarget(kind: .piSession, name: task.heading, ref: id), card: task.id, delivery: delivery, origin: .known(.cue))
        let fake = try await rig.app.host.connect(id, cwd: folder, busy: true)
        fake.sendInfo(["name": task.heading])
        let session = ScriptedSession(session: fake, task: task, history: [PiChatMessage(sessionID: id, entryID: "e1", seq: 1, role: .user, text: task.body, at: .now, deliveryID: delivery)])
        sessions.append(session)
        return session
    }

    /// 他在一件事上接着交代：Cue 可能对原来的会话说，也可能（那件已做完、会话已结束）另建任务开新会话。开了新会话就接着用新的。
    func continuing(_ session: ScriptedSession, _ topic: Regex<Substring>, after step: Step) async throws -> ScriptedSession {
        guard calls(step, "task", ["start"]).contains(where: { !$0.call.failed }) else { return session }
        var found: ScriptedSession?
        try? await eventually("Cue 开出的会话绑上任务") {
            found = try await self.opened(topic)
            return found != nil
        }
        guard let found else { return session }
        sessions.append(found)
        return found
    }

    func opened(_ topic: Regex<Substring>) async throws -> ScriptedSession? {
        let extensions = rig.app.host.extensions
        for (id, fake) in extensions where id.hasPrefix("new-") && !sessions.contains(where: { $0.id == id }) {
            guard let leaf = try await rig.store.tasks(boundTo: id).first else { continue }
            let top = leaf.parent ?? leaf.task
            // 新开在原来那件上的（那件已结束、照原任务另开新会话）新交代不在正文里，在 Cue 随后送进来的话里
            let said = fake.commands.compactMap { $0.json["text"] as? String }
            guard ([top.body, leaf.task.body] + said).joined(separator: "\n").contains(topic) else { continue }
            fake.setState(["kind": "thinking"])  // 开场白在接手前就到了：像真会话那样在干活
            return ScriptedSession(session: fake, task: top)
        }
        return nil
    }

    // MARK: 读这几步里的事

    func rounds(_ step: Step) -> [CueRound] {
        guard let window = step.window else { return [] }
        return eval.rounds.filter { window.contains($0.startedAt) }
    }

    func rounds(after step: Step) -> [CueRound] {
        guard let from = step.window?.lowerBound else { return [] }
        return eval.rounds.filter { $0.startedAt >= from }
    }

    func calls(_ step: Step, _ tool: String, _ actions: Set<String> = []) -> [(call: CueToolCall, args: [String: Any])] {
        CueEval.calls(in: rounds(step), tool, actions)
    }

    /// 这几步里成功对 `session` 说的话（say 的 text）
    func says(_ steps: [Step], to session: ScriptedSession) -> [String] {
        steps.flatMap { calls($0, "task", ["say"]) }.filter { !$0.call.failed && target($0.args) === session }.compactMap { $0.args["text"] as? String }
    }

    /// 去掉引号里转述的原话（“”「」""）
    static func unquoted(_ text: String) -> String { text.replacing(/“[^”]*”|「[^」]*」|"[^"]*"/, with: "") }

    /// 他问起早先的事：答对才过；没答对时标出是说不知道还是答错（乱编）
    /// `fabricated`：没答对、也没说不知道时，这句是不是给了一个具体的错答案（编造）。
    func recalled(
        _ label: String, _ step: Step, kind: CheckKind = .memory, fabricated: ((String) -> Bool)? = nil, _ correct: (String) -> Bool
    ) async throws -> Check {
        // 这一步里回他的每一句都算：碰上换新时，答他的那句之后新班次还会再回一句
        let answers = try await replies(step)
        if answers.contains(where: correct) { return Check(kind, label, true) }
        if answers.contains(where: { $0.contains(/不记得|不确定|没找到|查不到|没有记录|没查到|不知道|答不出|答不上|报不出|没统计|没查退信|没有.{0,6}记录/) }) {
            return Check(kind, label, false, note: "（说不知道）")
        }
        let made = fabricated.map { answers.contains(where: $0) } ?? false
        return Check(kind, label, false, note: made ? "（答错，编造）" : "（答错）")
    }

    /// 这一步里 Cue 写的消息（回复、tell、动态、完成的结果）
    func messages(_ step: Step) async throws -> [String] {
        guard let window = step.window else { return [] }
        return try await eval.said(since: window.lowerBound).filter { $0.createdAt <= window.upperBound }.map(\.text)
    }

    /// 这一步里回他的话（Cue 回复他、不关联任务、不带选项的）
    func replies(_ step: Step) async throws -> [String] {
        guard let window = step.window else { return [] }
        return try await eval.said(since: window.lowerBound)
            .filter { $0.author == .known(.cue) && $0.choices == nil && $0.taskID == nil && $0.createdAt <= window.upperBound }.map(\.text)
    }

    /// 回答他的那句（这一步里）
    func reply(_ step: Step) async throws -> String? { try await replies(step).last }

    /// 这一步里告诉他的：Cue 写的消息，加 tell 的 text
    func told(_ step: Step) async throws -> [String] {
        try await messages(step) + calls(step, "tell").compactMap { $0.args["text"] as? String }
    }

    /// 对同一个会话把同一件事说了两遍的会话（`similar`）
    func resaid() -> [ScriptedSession] {
        sessions.filter { session in
            let said = says(steps, to: session)
            return said.indices.contains { i in said[(i + 1)...].contains { Self.similar($0, said[i]) } }
        }
    }

    /// .md 里统计段的尾巴：剧本没按预想走的地方，与每一步叫醒了几轮、调了哪些工具
    func stepTable() -> [String] {
        notes.map { "- \($0)" } + ["", "| 步 | 叫醒的事 | 轮数 | 工具调用 |", "| --- | --- | --- | --- |"]
            + steps.enumerated().map { index, step in
                let rounds = rounds(step)
                return "| \(index + 1) | \(step.label) | \(rounds.count) | \(rounds.flatMap(\.calls).map(\.name).joined(separator: "、")) |"
            }
    }

    /// 工具参数指的是哪个会话（`CueEval.refers`）
    func target(_ args: [String: Any]) -> ScriptedSession? {
        sessions.first { CueEval.refers(args, to: $0.id, title: $0.title, cards: $0.cards) }
    }

    static func texts(_ args: [String: Any]) -> String {
        (["title", "body", "text"].compactMap { args[$0] as? String } + (args["steps"] as? [String] ?? [])).joined(separator: "\n")
    }

    /// 两句话几乎一样：去掉空白与标点后，相邻两字的集合重合八成以上
    static func similar(_ a: String, _ b: String) -> Bool {
        func pairs(_ text: String) -> Set<String> {
            let characters = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
            return Set(zip(characters, characters.dropFirst()).map { "\($0)\($1)" })
        }
        let x = pairs(a), y = pairs(b)
        guard !x.isEmpty, !y.isEmpty else { return a == b }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.8
    }

}

/// 一段剧本：跑完判定（`script`），写进 .md 的统计（`summarize`）不论跑没跑完都写。
@MainActor
protocol Playable: EvalScript {
    func script() async throws -> [Check]
    func summarize() async
}

extension Playable {
    func play() async throws -> [Check] {
        do {
            let checks = try await script()
            await summarize()
            return checks
        } catch {
            await summarize()
            throw error
        }
    }
}
#endif
