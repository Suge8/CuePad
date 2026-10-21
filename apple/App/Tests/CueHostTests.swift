#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

/// Cue 在 Mac 上值班，端到端：真实的 Pi 当大脑（RPC），真实的 `cuepad mcp`（App 里的那份）读写同一个隔离库，
/// 模型是本进程里的假 OpenAI 端点（按剧本回，零网络），执行器开的会话由假扩展扮演（`RecordingHost`）。
/// Pi 的配置在临时目录（`PI_CODING_AGENT_DIR`），不碰 ~/.pi 与真实资料库。
/// 本机的 Pi（真 Pi 的测试共用）
nonisolated let realPi = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/pi")

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"), .serialized, .timeLimit(.minutes(2)))
struct CueHostTests {
    /// 你的话送进 Cue 不受库忙不忙影响：十个会话的状态一刻不停地写着，说的话照样马上交给 Cue。
    @Test func 库正忙时你的话马上送进Cue() async throws {
        let rig = try await Rig()
        let store = rig.store
        let busy = Task {
            let recorder = PiStateRecorder(store: store, hostID: "mac-busy")
            var round = 0
            while !Task.isCancelled {
                round += 1
                for index in 0..<10 {
                    _ = try? await recorder.update(sessionID: "busy-\(index)", state: round.isMultiple(of: 2) ? .thinking : .tool, title: "会话 \(index)")
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { busy.cancel() }
        try await eventually("写入已经跑起来") { try await store.allPiSessionStates().count == 10 }
        try await rig.say("库正忙时说的")
        try await eventually("交给 Cue", timeout: .milliseconds(500)) {
            try await store.cueMessages().contains { $0.text == "库正忙时说的" && $0.deliveredAt != nil }
        }
        busy.cancel()
        await rig.stop()
    }

    /// 你说一句，Cue 的回答落库（写成 Cue 说的）；你的消息记下已交给大脑。Cue 的大脑不是 Agent 会话：不在会话列表、历史与 Pi 的会话目录里。
    @Test func 你说一句_Cue的回答落库() async throws {
        let rig = try await Rig()
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        #expect(try await rig.store.cueMessages().first { $0.author == .known(.you) }?.deliveredAt != nil)
        #expect(rig.services.pi.sessions.isEmpty)
        #expect(try await rig.store.allPiSessionStates().isEmpty)
        let sessions = rig.app.piPaths.sessionsDirectory
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).isEmpty)
        await rig.stop()
    }

    /// 你在 Cue 页发图：资料库里的图片引用转成图片交给大脑（假模型收到的是图片，不只是文字里的引用），Cue 照图回答。
    @Test func 你发图_Cue看得见() async throws {
        let rig = try await Rig()
        try await rig.say("这是什么？\n\(try rig.image())")
        try await rig.message(.cue, containing: "看到图了")
        await rig.stop()
    }

    /// 模型看不了图：明确告诉你图没交给它，文字照常交（Cue 照常回答）。
    @Test func 模型看不了图_告诉你() async throws {
        let rig = try await Rig(seesImages: false)
        try await rig.say("这是什么？\n\(try rig.image())")
        try await rig.message(.cue, containing: "看不了图")
        try await rig.message(.cue, containing: "收到：")
        await rig.stop()
    }

    @Test func 你的图_Cue转给会话() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 转图")
        try await rig.message(.cue, containing: "登录页那边歇下了")
        let image = try rig.image()
        try await rig.say("请把这张图转给登录页\n\(image)")
        let session = try #require(rig.app.host.extensions.values.first)
        try await eventually("会话收到图") { session.messages.contains { !$0.images.isEmpty } }
        let sent = try #require(session.messages.last { !$0.images.isEmpty })
        #expect(sent.text.contains("看这张") && !sent.text.contains("cuepad://"))
        #expect(sent.images.map(\.data) == [pngData(shade: 0.5)])
        await rig.stop()
    }

    @Test func 刚启用说过话_开场只有一条() async throws {
        let rig = try await Rig(asksOnEnable: true, prepare: Rig.handOverWork)
        try await eventually("回了最后一句") { rig.model.answered("已告诉用户") }
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) }
        let said = try await rig.store.cueMessages().filter { $0.author == .known(.cue) }
        #expect(said.map(\.text) == ["要交给我跟进吗？"])
        await rig.stop()
    }

    /// 手上什么都没有时启用：Cue 不醒来说"没有在做的事"，对话里只有你说的与它的回答（Cue 页空着时是能说什么的空态）。
    @Test func 空库启用_不说空话() async throws {
        let rig = try await Rig()
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let said = try await rig.store.cueMessages().filter { $0.author != .known(.you) }
        #expect(said.map(\.text) == ["收到：你好"])
        await rig.stop()
    }
}
#endif
