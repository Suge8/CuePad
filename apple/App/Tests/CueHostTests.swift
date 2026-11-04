#if os(macOS)
import CueAgent
import CuePi
@testable import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

/// Cue 在 Mac 上值班，端到端：真实的 Pi 当大脑（RPC），真实的 `cuepad mcp`（App 里的那份）读写同一个隔离库，
/// 模型是本进程里的假 OpenAI 端点（按剧本回，零网络），执行器开的会话由假扩展扮演（`RecordingHost`）。
/// Pi 的配置在临时目录（`PI_CODING_AGENT_DIR`），不碰 ~/.pi 与真实资料库。
/// 本机的 Pi（真 Pi 的测试共用）
nonisolated let realPi = ProcessInfo.processInfo.environment["CUEPAD_TEST_PI"].map { URL(filePath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/pi")

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"), .serialized)
struct CueHostTests {
    /// 你的话送进 Cue 不受库忙不忙影响：十个会话的状态一刻不停地写着，说的话照样交给 Cue——
    /// 不是等写入歇下才交。不量时长：写入到交出去为止一直在继续，交不出去由测试时限报。
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
        try await eventually("交给 Cue") {
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

    /// 收尾那一刻追问：会话的动静叫醒的那一轮在 Pi 里已收尾、还没报出来时你说一句，这台 Mac 以为那一轮还在跑、把话插进去，
    /// Pi 报完收尾另开一轮接走它。这句在接走它的那一轮得到回答、只答一次；叫醒的那一轮最后的话不当成回答你写进对话。
    @Test func 收尾那一刻追问_这句在下一轮得到回答_只答一次() async throws {
        let rig = try await Rig(settleGate: true)
        let held = try rig.armSettle()
        let remote = try await rig.remoteMac()
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        try await remote.update(sessionID: "remote-1", state: .settled)
        try await rig.answered("remote-1")
        try await held()
        try await rig.say("第二句")
        try await rig.handed("第二句")
        try rig.releaseSettle()
        try await rig.message(.cue, containing: "收到：第二句")
        try await eventually("Cue 歇下") { try await rig.store.cueState()?.state == .known(.settled) }
        #expect(try await rig.count("登录页那边歇下了") == 1)
        #expect(try await rig.count("收到：第二句") == 1)
        #expect(try await rig.count("办好了") == 0, "叫醒的那一轮没接走这句")
        await rig.stop()
    }

    /// 收尾那一刻改规矩又追问：叫醒的那一轮在 Pi 里已收尾、还没报出来时你钉上一条、再说一句，两句都插给了以为在跑的那一轮。
    /// 规矩一变这一轮做完就换班次：插进去的规矩不另开一轮、不写进对话，新班次照新规矩；你那句没被接走，退回交给新班次，只答一次。
    @Test func 收尾那一刻改规矩又追问_这句换班次后只答一次_规矩照样生效() async throws {
        let rig = try await Rig(settleGate: true)
        let held = try rig.armSettle()
        let remote = try await rig.remoteMac()
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        try await remote.update(sessionID: "remote-1", state: .settled)
        try await rig.answered("remote-1")
        try await held()
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you).line
        Workspace(services: rig.services).pinCueLine(line.id, true)
        try await rig.handed("一直记着的刚变了")
        try await rig.say("第二句")
        try await rig.handed("第二句")
        try rig.releaseSettle()
        try await rig.message(.cue, containing: "收到：第二句")
        try await eventually("Cue 歇下") { try await rig.store.cueState()?.state == .known(.settled) }
        #expect(try await rig.count("收到：第二句") == 1)
        #expect(try await rig.count("这一轮照新规矩") == 0, "插进去的规矩不写进对话")
        try await rig.say("一直记着什么")
        let answer = try await rig.message(.cue, containing: "一直记着：")
        #expect(answer.text.contains("推送前先问我"))
        #expect(try await rig.count("登录页那边歇下了") == 1)
        await rig.stop()
    }

    /// 你在 Cue 页发图：资料库里的图片引用转成图片交给大脑（假模型收到的是图片，不只是文字里的引用），Cue 照图回答。
    @Test func 你发图_Cue看得见() async throws {
        let rig = try await Rig()
        try await rig.say("这是什么？\n\(try rig.image())")
        try await rig.message(.cue, containing: "看到图了")
        await rig.stop()
    }

    /// 模型看不了图：同看不了图的会话一样，图写成"附件：图片.png（本机路径）"交给它（不另附图），Cue 照常回答。
    @Test func 模型看不了图_图写成路径交给它() async throws {
        let rig = try await Rig(seesImages: false)
        let image = try rig.image()
        try await rig.say("这是什么？\n\(image)")
        let key = try #require(CueFormat.attachmentKeys(in: image).first)
        let path = try #require(rig.store.files.fileURL(for: key)).path(percentEncoded: false)
        try await rig.message(.cue, containing: "图在 \(path)")
        #expect(try await rig.store.cueMessages().allSatisfy { !$0.text.contains("看不了图") })
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

    /// 你在记忆里把一条改成一直记着：Cue 下一轮就照它（系统提示跟上，不等换新）。
    @Test func 改了一直记着的规矩_下一轮就照新规矩() async throws {
        let rig = try await Rig()
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you).line
        Workspace(services: rig.services).pinCueLine(line.id, true)
        try await eventually("钉上了") { try await rig.store.cueMemory().lines.contains { $0.id == line.id && $0.pinned } }
        try await rig.say("一直记着什么")
        let answer = try await rig.message(.cue, containing: "一直记着：")
        #expect(answer.text.contains("推送前先问我"))
        await rig.stop()
    }

    /// Cue 正在跑一轮时你把一条改成一直记着：这一轮当场收到新规矩，接下来的动作照它，不等下一轮。
    @Test func 一轮在跑时改了规矩_这一轮就照新规矩() async throws {
        let rig = try await Rig()
        let keeper = try #require(rig.services.cue.keeper)
        try await rig.say("请等我放行")
        try await eventually("这一轮停在模型那里") { rig.model.holding }
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you).line
        Workspace(services: rig.services).pinCueLine(line.id, true)
        try await eventually("插给了在跑的大脑") { keeper.turn?.round.sent.contains { $0.contains("一直记着的刚变了") && $0.contains("推送前先问我") } == true }
        rig.model.release()
        let answer = try await rig.message(.cue, containing: "这一轮照新规矩")
        #expect(answer.text.contains("推送前先问我"))
        await rig.stop()
    }

    /// 别的设备上把一条旧记忆钉成一直记着、迟到才同步来（修改时间早于这台 Mac 上更晚记下的那条）：在跑的这一轮照样当场收到。
    @Test func 一轮在跑时别的设备迟到同步来的规矩_这一轮也照它() async throws {
        let rig = try await Rig()
        let keeper = try #require(rig.services.cue.keeper)
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you).line
        try await Task.sleep(for: .milliseconds(5))  // 之后记下的那条修改时间更晚
        try await rig.store.noteCueLine("周报每周五发", source: .you)
        try await rig.say("请等我放行")
        try await eventually("这一轮停在模型那里") { rig.model.holding }
        var row = try #require(try await rig.store.syncRow(recordName: line.id.uuidString.lowercased()))
        row.fields["pinned"] = .int(1)
        row.fields["modifiedAt"] = .int(Int64((line.modifiedAt.timeIntervalSince1970 * 1000).rounded()) + 1)
        #expect(try await rig.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        try await eventually("插给了在跑的大脑") { keeper.turn?.round.sent.contains { $0.contains("一直记着的刚变了") && $0.contains("推送前先问我") } == true }
        rig.model.release()
        let answer = try await rig.message(.cue, containing: "这一轮照新规矩")
        #expect(answer.text.contains("推送前先问我"))
        await rig.stop()
    }

    /// 额度只看 Cue 运行的这台 Mac（额度各台各登各的）：别的 Mac 上吃紧的账号不写进信封，这台的照写。
    @Test func 信封里的额度只写这台Mac的() async throws {
        let rig = try await Rig()
        let tight = [QuotaWindow(seconds: 18_000, used: 0.9, resetsAt: .now.addingTimeInterval(3600), isBinding: true)]
        for (host, name) in [(TestApp.hostID, "这台"), ("mac-b", "那台")] {
            try await rig.store.recordQuota(
                QuotaReport(provider: "anthropic", windows: tight, complete: true, account: PiAccount(kind: .oauth, scope: name, name: name)), host: host)
        }
        try await rig.say("额度吃紧吗")
        let answer = try await rig.message(.cue, containing: "额度吃紧：")
        #expect(answer.text.contains("「这台」") && !answer.text.contains("「那台」"))
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

    /// 手上什么都没有时启用、巡视也到点了：Cue 都不醒来说"没有在做的事"，对话里只有你说的与它的回答，没有醒来记录那一行
    /// （Cue 页空着时是能说什么的空态）。
    @Test func 空库启用与巡视_不说空话() async throws {
        let rig = try await Rig(patrolAfter: .zero)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let said = try await rig.store.cueMessages().filter { $0.author != .known(.you) }
        #expect(said.map(\.text) == ["收到：你好"])
        await rig.stop()
    }
}
#endif
