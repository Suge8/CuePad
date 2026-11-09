#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    @Test func 建任务开工_会话名模型强度照Cue指定的开() async throws {
        let rig = try await Rig()
        try await rig.say("请建个任务并开工")
        try await rig.message(.cue, containing: "办好了")
        try await eventually("执行器开出会话") { !rig.app.host.extensions.isEmpty }
        let session = try #require(rig.app.host.extensions.values.first)
        try await eventually("配置后送进草稿") { session.received.contains("send") }
        #expect(rig.app.host.calls.contains {
            if case .open(let directory, _, let name, let model, let thinking) = $0 {
                directory == rig.folder.path && name == "修好登录页" && model == "fake/m" && thinking == "high"
            } else { false }
        })
        #expect(session.messages.first?.text == "修好登录页\n把登录页修好")
        #expect(!session.received.contains("config"))
        await rig.stop()
    }

    @Test func 会话歇下后Cue什么都没做_写明谁叫醒的() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 只看看")
        func woke(_ count: Int) -> Bool { rig.rounds.filter { $0.wake.isSessionActivity && $0.finishedAt != nil }.count == count }
        try await eventually("被叫醒的那一轮做完") { woke(1) }
        let session = try #require(rig.app.host.extensions.values.first)
        let title = try #require(try await rig.store.sessions(matching: session.sessionID).first?.title)
        func notes() async throws -> [CueNoteRound] {
            let rows = try await CueThread.read(from: rig.store).rows
            guard case .notes(let rounds)? = rows.last else { return [] }
            return rounds
        }
        func glanced(_ round: CueNoteRound) -> Bool {
            guard let place = round.header?.places.first, round.header?.places.count == 1 else { return false }
            return round.outcome?.kind == .leave && place.title == title && place.kind == .settled
                && place.target == .session(PiSessionState.recordID(sessionID: session.sessionID), sessionID: session.sessionID)
        }
        let first = try await notes()
        #expect(first.count == 1 && first.allSatisfy(glanced), "\(first)")

        session.setState(["kind": "thinking"])
        try await eventually("又在干活") { try await rig.store.sessions(matching: session.sessionID).first?.state.isWorking == true }
        session.setState(["kind": "idle"])
        try await rig.answered(session.sessionID)
        try await eventually("又被叫醒的那一轮做完") { woke(2) }
        let both = try await notes()
        #expect(both.count == 2 && both.allSatisfy(glanced), "\(both)")

        session.sendInfo(["name": "改过名的会话"])
        try await eventually("改了名") { try await rig.store.sessions(matching: session.sessionID).first?.title == "改过名的会话" }
        let renamed = try await notes()
        #expect(renamed.count == 2 && renamed.allSatisfy(glanced), "\(renamed)")
        await rig.stop()
    }

    /// 照不照办看评测：长程的"做完顺手升 2.3.1"。
    @Test func 会话交回时_信封列着Cue更早托付的() async throws {
        let rig = try await Rig()
        try await rig.say("请建个任务并开工")
        try await eventually("开工这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("开新会话") }
        try await eventually("执行器开出会话") { !rig.app.host.extensions.isEmpty }
        let session = try #require(rig.app.host.extensions.values.first), id = session.sessionID
        let task = try #require(try await rig.store.cueBoard().tasks.first?.task)
        try await rig.store.linkCard(task.id, toSession: id)
        let context = String(repeating: "登录页的入口、填邮箱页和设新密码页照正文做，提示文案统一。", count: 10)
        let bump = context + "最后：做完后顺手把版本号升到 2.3.1，CHANGELOG 记一笔", his = "顺便看看登录页的字号"
        let last = context + "最后：交回时贴 git log -1 --stat", echoed = context + "最后：改完的页面截图发到手机"
        let file = try #require(rig.app.host.sessionFiles[id])
        func said(_ text: String, byCue: Bool = true) async throws {
            let delivery = UUID()
            if byCue { _ = try await rig.store.recordSend(text, to: SendTarget(kind: .piSession, name: task.heading, ref: id), card: task.id, delivery: delivery, origin: .known(.cue)) }
            try file.user(text, delivery: byCue ? delivery.uuidString : nil)
        }
        for (text, byCue) in [(bump, true), (bump, true), (his, false), (echoed, true), ("接着做第 1 页", true), (echoed, false)] {
            try await said(text, byCue: byCue)
            try file.reply("好")
        }
        session.setState(["kind": "thinking"])
        try await eventually("在干活写进库") { try await rig.store.sessions(matching: id).first?.state.isWorking == true }
        try await said(last)
        session.setState(["kind": "idle"])
        try await rig.answered(id, reply: "好")
        try await eventually("被叫醒的那一轮做完") { rig.rounds.contains { $0.wake.isSessionActivity && $0.finishedAt != nil } }
        let envelope = try #require(rig.rounds.last { $0.wake.isSessionActivity }).sent.joined()
        let earlier = envelope.components(separatedBy: "你更早对它说过的").dropFirst().first?.split(separator: "\n").dropFirst()
            .prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        #expect(bump.count > 300 && earlier.filter { $0.contains("2.3.1") } == ["- \(bump)"], "\(envelope)")
        #expect(earlier.contains("- \(echoed)") && envelope.contains("他：") && !envelope.contains("他：\(echoed)"), "\(envelope)")
        #expect(envelope.contains("你：\(last)") && !envelope.contains(his), "\(envelope)")
        await rig.stop()
    }

    /// 工具是读一个命名管道：没人往里写，读就停在那里，"工具进行中"一直在库里，断言完再写一行放行。
    @Test func Cue用工具时库里写下动作_说完回到歇着() async throws {
        let rig = try await Rig()
        let gate = rig.app.directory.appending(path: "gate")
        try #require(mkfifo(gate.path, 0o600) == 0)
        try await rig.say("请读一下关卡 \(gate.path)")
        try await eventually("读的时候库里写着在读") {
            let now = try await rig.store.cueState()
            return now?.state == .known(.tool) && now?.detail == "read · gate"
        }

        var writer: Int32 = -1
        try await eventually("关卡有人在读") { writer = open(gate.path, O_WRONLY | O_NONBLOCK); return writer >= 0 }
        _ = write(writer, "放行\n", "放行\n".utf8.count)
        close(writer)
        try await rig.message(.cue, containing: "办好了")
        try await eventually("这一轮歇下") { try await rig.store.cueState()?.state == .known(.settled) }
        await rig.stop()
    }

    @Test func 会话等回答时Cue马上醒来() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 要作答")
        let session = try #require(rig.app.host.extensions.values.first)
        session.setState(["kind": "waiting_user", "title": "允许使用 Bash？"])
        try await rig.message(.cue, containing: "去作答了")
        await rig.stop()
    }

    @Test func 开工失败_Cue醒来看到原因() async throws {
        let rig = try await Rig()
        rig.app.host.openFailure = #"Error: Model "fake/nope" not found"#
        try await rig.say("请建个任务并开工")
        try await rig.message(.cue, containing: "办好了")
        let seen = try await rig.message(.cue, containing: "看到了")
        #expect(seen.text.contains("修好登录页") && seen.text.contains("开工") && seen.text.contains(#"Model "fake/nope" not found"#))
        await rig.stop()
    }
}
#endif
