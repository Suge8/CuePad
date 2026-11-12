#if os(macOS)
import CueAgent
import CueBridge
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
                && place.target == .session(SessionState.recordID(sessionID: session.sessionID), sessionID: session.sessionID)
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

    /// `stop` 是假扩展报的停下（被打断是做到一半进程没了）。
    @Test(arguments: ["idle", "waiting_user", "error", "interrupted"])
    func 他开的一轮停下不叫醒Cue_当场留给他回(stop: String) async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 只看看")
        func woke() -> Int { rig.rounds.filter(\.wake.isSessionActivity).count }
        try await eventually("Cue 开的那一轮停下叫醒它，它做完") { woke() == 1 && rig.rounds.allSatisfy { $0.finishedAt != nil } }
        let session = try #require(rig.app.host.extensions.values.first)
        let file = try #require(rig.app.host.sessionFiles[session.sessionID])
        // 远处排一个定时：对账后睡下，`reconciled` 才等得到
        _ = try await rig.store.noteCueLine("下周的事", source: .you, remindAt: rig.clock.now.addingTimeInterval(7 * 86_400))

        try file.user("顺便看下注册页", at: .now - 15 * 60)  // 早过了"刚说过话"：停下时他不在场也不叫醒
        session.setState(["kind": "thinking"])
        try await eventually("在干活写进库") { try await rig.store.sessions(matching: session.sessionID).first?.state.isWorking == true }
        switch stop {
        case "idle":
            session.setState(["kind": "idle"])
            try await rig.answered(session.sessionID)
        case "interrupted": session.crash()
        default: session.setState(["kind": stop, "title": "要换个做法吗？", "error": "500 Internal server error"])
        }
        try await eventually("他那一轮的停下留给他回") {
            guard let state = try await rig.store.sessionState(session.sessionID) else { return false }
            return try await rig.store.cueState()?.left.contains { $0.holds(for: state) } == true
        }
        try await rig.reconciled()
        #expect(woke() == 1)
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
