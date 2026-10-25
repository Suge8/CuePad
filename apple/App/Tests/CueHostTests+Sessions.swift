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
    /// Cue 经工具建任务并开工：执行器在项目文件夹开出会话，会话名是任务标题、模型与思考强度是 Cue 指定的（启动参数，一步生效），再送进草稿。
    @Test func 建任务开工_会话名模型强度照Cue指定的开() async throws {
        let rig = try await Rig()
        try await rig.say("请建个任务并开工")
        try await rig.message(.cue, containing: "办好了")
        try await eventually("执行器开出会话") { rig.app.host.calls.contains { if case .open(let directory, _, _, _, _) = $0 { directory == rig.folder.path } else { false } } }
        let session = try #require(rig.app.host.extensions.values.first)
        try await eventually("配置后送进草稿") { session.received.contains("send") }
        #expect(rig.app.host.calls.contains {
            if case .open(_, _, let name, let model, let thinking) = $0 { name == "修好登录页" && model == "fake/fake-model" && thinking == "high" } else { false }
        })
        #expect(session.messages.first?.text == "修好登录页\n把登录页修好")
        #expect(!session.received.contains("config"))
        await rig.stop()
    }

    /// 会话的动静叫醒 Cue，它看了看、什么都没做（没有落了结果的一步）：这一轮最后的话不写进对话；Cue 页那一行写叫醒它的会话停下了、没说话，
    /// 点它去的就是那个会话。紧接着又这样看了同一个会话：同一格里再一行。会话之后改了名，这两行仍写当时的名字。
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
            return round.said.isEmpty && place.title == title && place.kind == .settled
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
        #expect(try await rig.store.cueMessages().allSatisfy { $0.author != .known(.note) || $0.text.isEmpty })
        await rig.stop()
    }

    /// Cue 用工具时，值班的 Mac 把它在做什么写进库（同步出去，各设备 Cue 页的头像与进展一行读这一处），这一轮说完回到歇着。
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

    /// 在做的会话在等回答（如"允许使用 Bash？"）：马上叫醒 Cue 去作答。
    @Test func 会话等回答时Cue马上醒来() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 要作答")
        let session = try #require(rig.app.host.extensions.values.first)
        session.setState(["kind": "waiting_user", "title": "允许使用 Bash？"])
        try await rig.message(.cue, containing: "去作答了", timeout: .seconds(5))
        await rig.stop()
    }

    /// Cue 开工，Mac 开不了会话（这里是 Pi 起来就退出）：这次失败是这件事的一条变化，叫醒 Cue，信封里写着动作与 Mac 报的原因。
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
