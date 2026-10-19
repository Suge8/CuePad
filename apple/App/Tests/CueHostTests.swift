#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Darwin
import Foundation
import Network
import Synchronization
import Testing
@testable import CuePad

/// Cue 在 Mac 上值班，端到端：真实的 Pi 当大脑（RPC），真实的 `cuepad mcp`（App 里的那份）读写同一个隔离库，
/// 模型是本进程里的假 OpenAI 端点（按剧本回，零网络），执行器开的会话由假扩展扮演（`RecordingHost`）。
/// Pi 的配置在临时目录（`PI_CODING_AGENT_DIR`），不碰 ~/.pi 与真实资料库。
/// 本机的 Pi（真 Pi 的测试共用）
nonisolated let realPi = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/pi")

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"), .serialized, .timeLimit(.minutes(2)))
struct CueHostTests {
    final class Rig {
        let model: FakeModel
        let notifier = RecordingCueNotifier()
        let app: TestApp
        let folder: URL
        var services: AppServices { app.services }
        var store: CueStore { services.store }

        /// `failingOnce`：信封里有这些话的请求，假模型第一次报错。
        /// `seesImages`：假模型能不能看图（Pi 的模型表里写的输入）。`asksOnEnable`：刚启用那一轮先用 tell 问你一句，再写最后的回复。
        /// `claude`：大脑换成真的 Claude Code（`CueEvalTests`），假模型的剧本不再用上。`patrolAfter`：空闲多久巡视一次。
        init(
            usage: Int = 100, failingOnce: [String] = [], seesImages: Bool = true, asksOnEnable: Bool = false, claude: ClaudeCue? = nil,
            patrolAfter: Duration = .seconds(3600)
        ) async throws {
            model = try FakeModel(usage: usage, failingOnce: failingOnce, asksOnEnable: asksOnEnable)
            let port = try await model.start()
            let timing = CueTiming(
                patrolAfter: patrolAfter, mergeAfter: .seconds(1),
                restarts: [.milliseconds(200), .milliseconds(200), .milliseconds(200)], retryWake: .seconds(1), quietHours: [])
            let launch = CueLaunch(executable: realPi, path: realPi.deletingLastPathComponent().path + ":/usr/bin:/bin", agents: [])
            let claudeLaunch = try claude.map { try $0.launch(in: TestLibraries.makeDirectory()) }
            app = TestApp(cue: CueDependencies(
                launch: { agent, _ in agent == .pi ? launch : agent == .claudeCode ? claudeLaunch : nil }, helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/cuepad"), notifier: notifier, timing: timing))
            let agent = app.piPaths.agentDirectory
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            try Data(#"{"providers":{"fake":{"baseUrl":"http://127.0.0.1:\#(port)/v1","api":"openai-completions","apiKey":"fake","models":[{"id":"fake-model","contextWindow":200000,"input":\#(seesImages ? #"["text","image"]"# : #"["text"]"#)},{"id":"fake-model-2","contextWindow":200000,"reasoning":true,"input":["text"]}]}}}"#.utf8)
                .write(to: agent.appending(path: "models.json"))
            try Data(#"{"defaultProvider":"fake","defaultModel":"fake-model"}"#.utf8).write(to: agent.appending(path: "settings.json"))
            folder = app.directory.appending(path: "demo", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await app.services.store.createProject(name: "演示", color: "blue")
            try await app.services.store.setDirectory(folder.path, for: project.id)
            try await app.connect(.pi)
            app.services.start()
            if let claude {
                try await claude.enable(self)
                return
            }
            try await app.services.enableCue(on: TestApp.hostID)
            try await message(.cue, containing: asksOnEnable ? "要交给我跟进吗？" : "我看了一眼")  // 刚启用的第一次醒来：你正看着屏幕，正常显示
        }

        func stop() async {
            await services.cue.stop()()
            services.cancelBackgroundWork()
            model.stop()
        }

        /// 请 Cue 建任务并开工，会话开出来后绑上叶子、改成这个标题（标题进信封，假模型按它演），然后让会话做完一轮歇下；
        /// 会话要等开工这一轮做完才歇下：同一刻歇下的，状态记进库时可能已落在这一轮前移的基线之前，Cue 就看不到这处变化。
        /// 等的是开工结果之后那句回复、且 Cue 空闲：只等"办好了"会撞上更早一轮的同一句。
        func settleTask(titled title: String) async throws {
            try await say("请建个任务并开工")
            try await eventually("开工这一轮做完") { try await self.store.cueState()?.state == .known(.settled) && self.model.answered("开新会话") }
            try await eventually("执行器开出会话") { !self.app.host.extensions.isEmpty }
            let session = try #require(app.host.extensions.values.first)
            let task = try #require(try await store.cueBoard().tasks.first?.task)
            // 认领：真实扩展在 hello 里带开会话的标识，假扩展不带，这里直接把叶子绑上它
            try await store.linkCard(task.id, toSession: session.sessionID)
            try await store.updateCard(task.id) { $0.body = title }
            session.setState(["kind": "thinking"])
            session.setState(["kind": "idle"])
            try await answered(session.sessionID)
        }

        /// 会话这一轮的回复读到了：像 Mac 读会话文件那样写下问答。放在歇下写进库之后，是回复晚于状态到的那一路
        /// （Claude Code 的轮末标记写在报歇下的钩子之后）：Cue 要等读到回复才醒，信封里带着它。
        /// `messages` 是这时读到的对话（peek 里看得到）。
        func answered(_ sessionID: String, prompt: String = "接着做", reply: String = "好了", messages: [PiChatMessage] = []) async throws {
            try await eventually("歇下写进库") { try await self.store.sessions(matching: sessionID).first?.state == .known(.settled) }
            try await store.writePiTranscript(PiTranscript(sessionID: sessionID, messages: messages, recap: PiRecap(lastPrompt: prompt, lastReply: reply, answeredAt: .now)))
        }

        /// 你对 Cue 说一句。
        func say(_ text: String) async throws { try await store.addCueMessage(.you, text: text) }

        /// 存一张图进库，返回写进正文的引用。
        func image() throws -> String { CueFormat.imageMarkup(id: try store.files.store(pngData(shade: 0.5))) }

        /// 等到出现一条 `author` 写的、含 `text` 的消息。默认上限比条件等待宽：中间隔着真 Pi 大脑起进程、读剧本。
        @discardableResult
        func message(_ author: CueAuthor, containing text: String, timeout: Duration = .seconds(15)) async throws -> CueMessage {
            var found: CueMessage?
            try await eventually("\(author) 说「\(text)」", timeout: timeout) {
                found = try await self.store.cueMessages().last { $0.author == .known(author) && $0.text.contains(text) }
                return found != nil
            }
            return found!
        }

        /// 这个 Rig 的 Cue 的大脑：本测试进程的子进程里，工作目录是这个库的 Cue 工作目录的（别的测试也在起 Pi）。
        var brainPIDs: [pid_t] {
            let work = app.directory.appending(path: "Library/Cue/work").resolvingSymlinksInPath().path
            var pids = [pid_t](repeating: 0, count: 256)
            let count = Int(proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
            return pids.prefix(max(0, count)).filter { pid in
                guard pid > 0 else { return false }
                var info = proc_vnodepathinfo()
                guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return false }
                let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return URL(filePath: cwd).resolvingSymlinksInPath().path == work
            }
        }
    }

    /// 你的话送进 Cue 不受库忙不忙影响：十个会话的状态一刻不停地写着，说的话照样马上交给 Cue。
    /// （别的设备上说的话经主动拉取到达这台 Mac，那一段见 CueSync 的 `CueMessageArrivalTests`。）
    @Test func 库正忙时你的话马上送进Cue() async throws {
        let rig = try await Rig()
        let store = rig.store
        let busy = Task {
            let recorder = PiStateRecorder(store: store, hostID: "mac-busy")
            var round = 0
            while !Task.isCancelled {
                round += 1
                for index in 0..<10 {
                    try? await recorder.update(sessionID: "busy-\(index)", state: round.isMultiple(of: 2) ? .thinking : .tool, title: "会话 \(index)")
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { busy.cancel() }
        try await Task.sleep(for: .milliseconds(300))  // 写入已经跑起来
        let start = ContinuousClock.now
        try await rig.say("库正忙时说的")
        try await eventually("交给 Cue", timeout: .milliseconds(500)) {
            try await store.cueMessages().contains { $0.text == "库正忙时说的" && $0.deliveredAt != nil }
        }
        print("送进 Cue：\(ContinuousClock.now - start)")
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

    /// 你在 Cue 页发图：图交给大脑（假模型收到的是图片，不只是文字里的引用），Cue 照图回答。
    @Test func 你发图_Cue看得见() async throws {
        let rig = try await Rig()
        try await rig.say("这是什么？\n\(try rig.image())")
        try await rig.message(.cue, containing: "看到图了")
        await rig.stop()
    }

    /// Cue 正在跑一轮（在查东西）时你发来图：图插进这一轮，下一次请求模型时就带着。
    @Test func 一轮中途发图_插进这一轮也带图() async throws {
        let rig = try await Rig()
        try await rig.say("请先查一下")
        try await eventually("Cue 在查") { rig.model.holding }
        try await rig.say("还有这张\n\(try rig.image())")
        try await eventually("交给了大脑") { try await rig.store.cueMessagesToDeliver().isEmpty }
        rig.model.release()
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

    /// 你请 Cue 把图转给干活的会话：Cue 把图的引用写进 task say，会话收到的投送里就是这张图。
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

    /// 刚启用那一轮已经用 tell 对你说过话了：最后那句回复不再另写一条，开场只有一条。
    @Test func 刚启用说过话_开场只有一条() async throws {
        let rig = try await Rig(asksOnEnable: true)
        try await eventually("回了最后一句") { rig.model.answered("已告诉用户") }
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) }
        let said = try await rig.store.cueMessages().filter { $0.author == .known(.cue) }
        #expect(said.map(\.text) == ["要交给我跟进吗？"])
        await rig.stop()
    }

    /// Cue 经工具建任务并开工：执行器在项目文件夹开出会话，会话名是任务标题、模型与思考强度是 Cue 指定的（启动参数，一步生效），再送进草稿。
    /// 会话歇下后 Cue 马上自己醒来。
    @Test func 建任务开工_会话歇下后Cue醒来() async throws {
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

        // 认领：真实扩展在 hello 里带开会话的标识，假扩展不带，这里直接把叶子绑上它
        let task = try #require(try await rig.store.cueBoard().tasks.first?.task)
        try await rig.store.linkCard(task.id, toSession: session.sessionID)
        session.setState(["kind": "thinking"])
        session.setState(["kind": "idle"])
        try await rig.answered(session.sessionID)
        try await rig.message(.cue, containing: "登录页那边歇下了")
        await rig.stop()
    }

    /// 会话的动静叫醒 Cue，它看了看、什么都没做（没有落了结果的一步）：这一轮最后的话不写进对话，没有灰色的一行。
    @Test func 会话歇下后Cue什么都没做_不写动态() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 只看看")
        try await eventually("被叫醒的那一轮做完") { rig.rounds.contains { $0.wake == .sessionActivity && $0.finishedAt != nil } }
        #expect(try await rig.store.cueMessages().allSatisfy { $0.author != .known(.note) })
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

    /// Cue 对开着的会话说话，过了说话工具等结果的时限（`Speech.cueWait`）Mac 才回报没送达（会话已关闭）：工具如实说还没送达；
    /// 失败一到就叫醒 Cue，信封里是"[发送失败] 任务 · 原因"；会话页那句话的气泡写着同一个原因。
    /// 会话开在另一台 Mac 上：说话请求由那台执行，本机的执行器不碰它；时限过后由替身当那台 Mac 写回失败。
    @Test func 说话过了时限才没送达_Cue马上醒来看到原因() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-1")
        try await PiStateRecorder(store: rig.store, hostID: "mac-b").update(sessionID: "remote-1", state: .settled, title: "修好登录页")
        try await rig.say("请对登录页说继续")
        try await eventually("这一轮做完", timeout: .seconds(90)) {
            try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("已发出，还没送达")
        }
        let sent = try #require(try await rig.store.deliveryRequests(toSession: "remote-1").last)
        #expect(sent.hostID == "mac-b" && sent.isOpen && sent.isFromCue)

        let macB = DeliveryExecutor(store: rig.store, hostID: "mac-b", onIssue: { Issue.record("\($0)") }) { _ in .failed("会话已关闭") }
        try await macB.start()
        let seen = try await rig.message(.cue, containing: "看到了")
        #expect(seen.text.contains("[发送失败] 修好登录页 说不出去") && seen.text.contains("会话已关闭"), "\(seen.text)")
        let failed = try #require(try await rig.store.deliveryRequest(sent.id))
        #expect(Said.request(failed).trip(at: .always(at: .now)) == .failed(.reported("会话已关闭")))
        await macB.stop()
        await rig.stop()
    }

    /// 说话工具在等结果的时限内拿到没送到、当场报给 Cue（标成出错、带原因），这一轮好好做完：Cue 已经知道了，这次失败不再进变化。
    @Test func 工具当场报了没送到_这一轮做完后不再报第二遍() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-3")
        try await PiStateRecorder(store: rig.store, hostID: "mac-b").update(sessionID: "remote-3", state: .settled, title: "修好登录页")
        let macB = DeliveryExecutor(store: rig.store, hostID: "mac-b", onIssue: { Issue.record("\($0)") }) { _ in .failed("会话已关闭") }
        try await macB.start()
        try await rig.say("请对登录页说继续")
        try await eventually("工具当场报了没送到") { rig.model.answered("没送到——会话已关闭") }
        try await eventually("这一轮做完、记下 Cue 已知道") {
            let failed = try await rig.store.deliveryRequests(toSession: "remote-3").contains { $0.failure != nil }
            let reported = try await rig.store.cueChanges(after: CueMarks(0)).contains { $0.kind == .undelivered }
            return failed && !reported
        }
        await macB.stop()
        await rig.stop()
    }

    /// Cue 说话的工具还在等结果时这一轮断了（大脑被杀；重启、更新、崩溃都是这样）：工具的回应没交到 Cue 手上，
    /// 随后的失败哪怕落在等结果的时限内，也写进下一轮的变化，Cue 醒来看到 [发送失败]。
    @Test func 说话工具等结果时断了_随后的失败下一轮看到() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 半路断开", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-2")
        try await PiStateRecorder(store: rig.store, hostID: "mac-b")
            .update(sessionID: "remote-2", state: .settled, title: "修好登录页", turnStartedAt: .now)
        try await rig.answered("remote-2")
        try await eventually("Cue 说了话、工具在等结果") {
            try await rig.store.deliveryRequests(toSession: "remote-2").contains { $0.isOpen && $0.isFromCue }
        }
        let brain = try #require(rig.brainPIDs.first)
        kill(brain, SIGKILL)

        let macB = DeliveryExecutor(store: rig.store, hostID: "mac-b", onIssue: { Issue.record("\($0)") }) { _ in .failed("会话已关闭") }
        try await macB.start()
        let seen = try await rig.message(.cue, containing: "看到了")
        #expect(seen.text.contains("[发送失败] 修好登录页 半路断开") && seen.text.contains("会话已关闭"), "\(seen.text)")
        await macB.stop()
        await rig.stop()
    }

    /// Cue 对已结束的本机会话说话，唤醒时它没及时起来（暂时性错误）：执行器隔一会儿重试一次就送到了。
    /// 说话工具等到结果、说已送达（结果由 App 进程写下，`cuepad mcp` 进程订阅库的变化看得到），会话页的气泡是已送达，Cue 收不到失败。
    @Test func 唤醒没及时起来_重试一次送到_Cue不收到失败() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.upsertPiSession(
            IndexedSession(id: "local-1", path: "/sessions/--demo--/local-1.jsonl", cwd: rig.folder.path, title: "修好登录页", lastActivityAt: .now),
            host: TestApp.hostID)
        try await rig.store.linkCard(task.id, toSession: "local-1")
        rig.app.host.resumeFailures = [AgentRuntimeError.launchTimedOut(.pi)]
        try await rig.say("请对登录页说继续")
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("已送达") }
        #expect(rig.app.host.calls.count == 2)  // 第一次没起来，重试那次起来了
        let sent = try #require(try await rig.store.deliveryRequests(toSession: "local-1").last)
        #expect(Said.request(sent).trip(at: .always(at: .now)) == .delivered)
        #expect(try await rig.store.cueChanges(after: CueMarks(0)).allSatisfy { $0.kind != .undelivered && $0.kind != .failed })
        await rig.stop()
    }

    /// 会话歇下的事件比它写进库早（这台机器忙、或从另一台 Mac 同步过来）：写进库时 Cue 已经做完了一轮、基线已经越过这个时刻，
    /// Cue 仍然要醒来看到它，不能因为事件时刻早于基线就漏掉。
    @Test func 歇下晚到_事件时刻早于上一轮_Cue仍然醒来() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 晚到", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-1")
        let remote = PiStateRecorder(store: rig.store, hostID: "mac-b")
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        let settledAt = Date.now
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) }
        try await remote.update(sessionID: "remote-1", state: .settled, times: PiTimes(stateSince: settledAt, busySince: nil))
        try await rig.answered("remote-1")
        try await rig.message(.cue, containing: "登录页那边歇下了")
        await rig.stop()
    }

    /// Cue 的请求失败晚到（从执行它的那台 Mac 同步过来时，完成时刻早于这台已经知道的另一次失败）：仍是新变化，Cue 醒来看到它。
    @Test func 请求失败晚到_完成时刻更早_Cue仍然醒来() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-1")
        let remote = PiStateRecorder(store: rig.store, hostID: "mac-b")
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        try await remote.update(sessionID: "remote-1", state: .settled)
        try await rig.answered("remote-1")
        try await rig.message(.cue, containing: "登录页那边歇下了")

        /// 你请 Cue 对会话说一句，这一轮做完后由替身当那台 Mac 按 `clock` 的时刻回报没送达，Cue 醒来看到 `reason`。
        func sayFails(_ reason: String, at clock: Timing) async throws {
            try await rig.say("请对登录页说继续")
            // 说话工具等结果至多 `Speech.cueWait`。歇着要晚于这句写下：上一轮刚做完、这一轮还没记成在跑时，歇着是旧的，
            // 这时就替那台 Mac 回报，说话工具当场拿到没送到、Cue 不会再被叫醒
            try await eventually("这一轮做完", timeout: .seconds(60)) {
                guard let cue = try await rig.store.cueState(), cue.state == .known(.settled) else { return false }
                return try await rig.store.deliveryRequests(toSession: "remote-1").contains { $0.isOpen && $0.createdAt < cue.modifiedAt }
            }
            let macB = DeliveryExecutor(store: rig.store, hostID: "mac-b", timing: clock, onIssue: { Issue.record("\($0)") }) { _ in .failed(reason) }
            try await macB.start()
            try await rig.message(.cue, containing: reason)
            await macB.stop()
        }
        try await sayFails("会话已关闭", at: .system)
        try await sayFails("早一小时就关了", at: ManualTiming(start: .now.addingTimeInterval(-3600)).timing)
        await rig.stop()
    }

    /// Cue 请你允许推送；你选"以后推送代码都不用问"后 Cue 被唤醒，回答写成 Cue 说的，允许清单记上推送（不进记忆）；
    /// 它再问推送就被拒、叫它直接做。"等你"推了通知（正文是要你定什么，不露原话）。
    @Test func 等你被回答_Cue被唤醒_以后都不用问记进允许清单() async throws {
        let rig = try await Rig()
        try await rig.say("请问我一个问题")
        let question = try await rig.message(.cue, containing: "要推送吗？")
        #expect(question.choices == ["可以", "以后推送代码都不用问"])
        try await eventually("推了通知") {
            rig.notifier.posted.map(\.body) == ["可以推送登录页的修复吗？\n可以 / 以后推送代码都不用问"]
        }
        try await rig.message(.cue, containing: "办好了")
        try await Workspace(services: rig.services).answerCueQuestion(question, "以后推送代码都不用问")
        try await rig.message(.cue, containing: "知道了：以后推送代码都不用问")
        #expect(try await rig.store.cueProfile()?.allows == [CueAllow(.push, project: nil)])
        #expect(try await rig.store.cueMemory().lines.isEmpty)
        await #expect(throws: CueStoreError.alreadyAllowed(nil)) { try await rig.store.addCueMessage(.cue, text: "又要推送吗？", ask: try CueAsking(.push, action: "推送修复")) }
        await rig.stop()
    }

    /// Cue 自己醒来的一轮出错（多是网络偶发）：先不告诉你，基线不前移；隔一会儿再醒一次，成了就照常。
    /// 刚启用那一轮出错，重试后照常看一眼；会话有动静那一轮出错，重试时看到的还是同一处变化，成了照常。
    @Test func 自己醒来出错后隔一会儿重试() async throws {
        let rig = try await Rig(failingOnce: ["醒来：刚启用"])  // 等到"我看了一眼"才返回
        #expect(rig.model.errors == 1)
        try await rig.settleTask(titled: "修好登录页 先出一次错")  // 假模型据此第一次报错
        try await rig.message(.cue, containing: "登录页那边歇下了")
        #expect(rig.model.errors == 2)
        #expect(try await rig.store.cueMessages().allSatisfy { !$0.text.contains("bad things happened") })
        await rig.stop()
    }

    /// 重试也出错：这时才写一条 Cue 的消息告诉你，只说一次。
    @Test func 自己醒来重试也出错才告诉你() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 先出两次错")
        try await rig.message(.cue, containing: "bad things happened")
        #expect(rig.model.errors == 2)
        #expect(try await rig.store.cueMessages().filter { $0.text.contains("bad things happened") }.count == 1)
        await rig.stop()
    }

    /// 会话交了结果，Cue 自己醒来做完（task done）：Cue 自己按证据确认，顶层任务直接完成，不请你确认，给你写一条结果（不是"等你"）；
    /// 这就是对你说过话了，最后那句回复不再写成灰色的一行（几乎是同一句）。
    @Test func 自己醒来做完_告诉你结果_不再写动态() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 请收一下")  // 假模型据此 done
        let report = try await rig.message(.cue, containing: "做完了")
        #expect(report.choices == nil && report.text.contains("- 登录测试全过"))
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("结果已告诉用户") }
        #expect(try await rig.store.card(try #require(report.taskID))?.status == .done)
        #expect(try await rig.store.cueMessagesWaitingForYou().isEmpty)
        #expect(try await rig.store.cueMessages().filter { $0.author == .known(.note) && $0.createdAt >= report.createdAt }.isEmpty)
        await rig.stop()
    }

    /// 你在别处记下的记忆多到要合并（超过视图预算）：空闲一会儿后 Cue 醒来，按合并提示写摘要。没有别的事件也会醒。
    @Test func 记忆待合并时空闲后醒来合并() async throws {
        let rig = try await Rig()
        for index in 0..<(CueMemoryView.budget + 4) { try await rig.store.noteCueLine("偏好 \(index)", source: .you) }
        try await rig.message(.cue, containing: "记忆合并好了")
        await rig.stop()
    }

    /// 大脑在一轮中途被杀：这一轮里交出去的你的话退回，重起后重新交给新的大脑，照常回答。
    @Test func 一轮中途被杀_你的话重新交出() async throws {
        let rig = try await Rig()
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("请慢慢想")
        try await eventually("交给了大脑") { try await rig.store.cueMessagesToDeliver().isEmpty }
        try await eventually("Cue 在想") { try await rig.store.cueState()?.state.isWorking == true }
        kill(first, SIGKILL)
        try await rig.message(.cue, containing: "收到：请慢慢想")
        #expect(!rig.brainPIDs.contains(first))
        await rig.stop()
    }

    /// 一件事分三步同时做、各开着会话：Cue 的信封里三步都在（不只当前那一步）；其中一步的会话做到一半断开（进程没了，
    /// 重启、更新、崩溃都是这样），Cue 醒来看到的是它被打断了，不是歇着。
    @Test func 并行的三步都在信封里_做到一半断开的显示被打断() async throws {
        let rig = try await Rig()
        let store = rig.store
        let project = try #require(try await store.projects().first)
        let task = try await store.createTask("三步并行", in: project.id)
        let titles = ["会话绑定多任务", "提示音和提示窗", "账号配额"]
        var sessions: [FakeExtension] = []
        for (index, title) in titles.enumerated() {
            let step = try await store.createTask(title, under: task.id)
            let file = rig.folder.appending(path: "s\(index).jsonl")
            try Data("{}\n".utf8).write(to: file)
            // 先绑上再连上（同从任务开会话）：会话一出现就在这一步下
            try await store.linkCard(step.id, toSession: "s\(index)")
            sessions.append(try await rig.app.host.connect("s\(index)", cwd: rig.folder.path, busy: true, sessionFile: file.path))
        }
        try await eventually("三个会话都记下在干活") { try await store.allPiSessionStates().filter { $0.state.isWorking }.count == 3 }

        try await rig.say("念一下看板")
        let board = try await rig.message(.cue, containing: "看板：")
        for title in titles { #expect(board.text.contains(title), "信封里有「\(title)」") }

        sessions[1].crash()
        let after = try await rig.message(.cue, containing: "被打断")
        let lines = after.text.split(separator: "\n")
        #expect(lines.first { $0.contains("提示音和提示窗") }?.contains("被打断") == true)
        #expect(lines.filter { $0.contains("被打断") }.count == 1)
        for title in [titles[0], titles[2]] { #expect(lines.first { $0.contains(title) }?.contains("工作中") == true) }
        await rig.stop()
    }

    /// 重启 CuePad 时托管的会话还在跑（它不随 App 退出）：启动对账不把它记为被打断，Cue 看到的仍是工作中。
    /// 刚升级、还没记下进程的会话（升级前写的记录）不知道还在不在，原样不动：仍是工作中，说明与子代理都在，不写成歇着或被打断。
    @Test func 重启时还活着的托管会话不算被打断() async throws {
        let rig = try await Rig()
        let store = rig.store
        let project = try #require(try await store.projects().first)
        let task = try await store.createTask("三步并行 托管着", in: project.id)
        let running = try await store.createTask("托管着在跑", under: task.id), upgraded = try await store.createTask("升级前就在跑", under: task.id)
        let file = rig.folder.appending(path: "h0.jsonl")
        try Data("{}\n".utf8).write(to: file)
        _ = try await rig.app.host.connect("h0", cwd: rig.folder.path, busy: true, hosted: true, sessionFile: file.path)
        try await store.linkCard(running.id, toSession: "h0")
        // 升级前写的记录：在跑、托管的，本机没有它的进程
        let helper = PiSubagentState(name: "helper", role: "工程师", phase: .known(.running))
        try await PiStateRecorder(store: store, hostID: TestApp.hostID)
            .update(sessionID: "h1", state: .tool, detail: "bash · swift test", hosted: true, subagents: [helper])
        try await store.linkCard(upgraded.id, toSession: "h1")
        try await eventually("记下在干活") { try await store.allPiSessionStates().filter { $0.state.isWorking }.count == 2 }

        try await rig.services.resetPiState()  // 启动对账：桥上的托管会话还连着，它的进程还在
        let states = Dictionary(uniqueKeysWithValues: try await store.allPiSessionStates().map { ($0.sessionID, $0) })
        #expect(states["h0"]?.state == .known(.thinking))
        #expect(states["h1"]?.state == .known(.tool) && states["h1"]?.detail == "bash · swift test" && states["h1"]?.subagents == [helper])
        try await rig.say("念一下看板")
        let board = try await rig.message(.cue, containing: "看板：")
        let lines = board.text.split(separator: "\n")
        for step in ["托管着在跑", "升级前就在跑"] { #expect(lines.first { $0.contains(step) }?.contains("工作中") == true, "\(step)") }
        #expect(!board.text.contains("被打断") && !board.text.contains("歇着"))
        await rig.stop()
    }

    /// 上下文到了换新线（刚启用那一轮就用到了）：下一次醒来提示先写交接；交接写好、这一轮结束后换新班次，第一轮带着交接醒来。
    @Test func 写交接后新班次接上() async throws {
        let rig = try await Rig(usage: 70_000)
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("第一句")
        try await rig.message(.handoff, containing: "交接：在跟登录页")
        try await rig.message(.cue, containing: "接上了：交接：在跟登录页")  // 写下交接的那一轮是你发起的：换新后照样给你看
        #expect(rig.brainPIDs.count == 1 && rig.brainPIDs.first != first)
        await rig.stop()
    }
}

/// 本进程里的假 OpenAI chat completions 端点（流式）：按最后一条消息照剧本回，用量固定为 `usage` 个输入 token。
/// 剧本里有的只演第一次（`once`）：第一次出错、第一次不回（连接挂着，等大脑被杀）。
nonisolated final class FakeModel: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-model")
    private let usage: Int
    private let played = Mutex<[String: Int]>([:])
    private let errorCount = Mutex(0)
    /// 回过几次错
    var errors: Int { errorCount.withLock { $0 } }
    private let failingOnce: [String]
    private let asksOnEnable: Bool
    /// 压着没回的请求（"请先查一下"那一轮）：`release()` 时才回，回的是调一次 ls
    private let held = Mutex<NWConnection?>(nil)
    /// 回过最后一句的工具结果（工具调用之后这一轮就结束）
    private let finishedAfter = Mutex<[String]>([])
    /// 不回的请求的连接：留着，免得释放时断开
    private let hung = Mutex<[NWConnection]>([])

    private enum Reply {
        case delta([String: Any], finish: String)
        case error(String)
        case hang
        /// 先压着，`release()` 时再回
        case held
    }

    init(usage: Int, failingOnce: [String] = [], asksOnEnable: Bool = false) throws {
        self.failingOnce = failingOnce
        self.asksOnEnable = asksOnEnable
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.usage = usage
    }

    func start() async throws -> UInt16 {
        let (ports, port) = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: port.yield(listener.port?.rawValue)
            case .failed, .cancelled: port.yield(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        for await value in ports { if let value { return value } else { break } }
        throw URLError(.cannotConnectToHost)
    }

    func stop() { listener.cancel() }

    /// 有压着没回的请求
    var holding: Bool { held.withLock { $0 != nil } }

    /// 回压着的那个请求。
    func release() {
        guard let connection = held.withLock({ value in defer { value = nil }; return value }) else { return }
        let call: [String: Any] = ["index": 0, "id": "call-ls", "type": "function", "function": ["name": "ls", "arguments": #"{"path":"."}"#]]
        send(connection, .delta(["role": "assistant", "tool_calls": [call]], finish: "tool_calls"))
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let body = Self.body(buffer) { return self.respond(connection, body) }
            if done || error != nil { return connection.cancel() }
            self.read(connection, buffer)
        }
    }

    private static func body(_ data: Data) -> Data? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
        let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[end.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    /// 收到的每个请求用的模型与思考强度（没带强度为 nil），先后有序
    private let requested = Mutex<[(model: String, effort: String?)]>([])
    var requests: [(model: String, effort: String?)] { requested.withLock { $0 } }

    private func respond(_ connection: NWConnection, _ body: Data) {
        let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        requested.withLock { $0.append((request["model"] as? String ?? "", request["reasoning_effort"] as? String)) }
        send(connection, script(request))
    }

    private func send(_ connection: NWConnection, _ reply: Reply) {
        let delta: [String: Any], finish: String
        switch reply {
        case .held: return held.withLock { $0 = connection }
        case .hang: return hung.withLock { $0.append(connection) }
        case .error(let message):
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "invalid_request_error"]]), as: UTF8.self)
            let out = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n" + json
            return connection.send(content: Data(out.utf8), completion: .contentProcessed { _ in connection.cancel() })
        case .delta(let value, let reason): (delta, finish) = (value, reason)
        }
        var out = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        let usage: [String: Any] = ["prompt_tokens": usage, "completion_tokens": 5, "total_tokens": usage + 5]
        for choice in [["index": 0, "delta": delta] as [String: Any], ["index": 0, "delta": [String: Any](), "finish_reason": finish]] {
            var chunk: [String: Any] = ["id": "x", "object": "chat.completion.chunk", "created": 0, "model": "fake-model", "choices": [choice]]
            if choice["finish_reason"] != nil { chunk["usage"] = usage }
            out += "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\n\n"
        }
        out += "data: [DONE]\n\n"
        connection.send(content: Data(out.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// 剧本：看最后一条消息。工具的结果——建好了任务就开工，否则说"办好了"；你的话与信封——按关键词调工具或回一句。
    /// 已就结果含 `fragment` 的工具调用回了这一轮最后一句。
    func answered(_ fragment: String) -> Bool { finishedAfter.withLock { $0.contains { $0.contains(fragment) } } }

    /// 这一出还没演满 `times` 次：记一次，返回 true。
    private func once(_ key: String, times: Int = 1) -> Bool {
        played.withLock { played in
            guard played[key, default: 0] < times else { return false }
            played[key, default: 0] += 1
            return true
        }
    }

    private func fail() -> Reply {
        errorCount.withLock { $0 += 1 }
        return .error("bad things happened")
    }

    private func script(_ request: [String: Any]) -> Reply {
        let tools = (request["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        func tool(_ suffix: String) -> String { tools.first { $0.hasSuffix(suffix) } ?? suffix }
        func call(_ suffix: String, _ arguments: [String: Any]) -> Reply {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            return .delta(["role": "assistant", "tool_calls": [["index": 0, "id": "call-\(UUID().uuidString.prefix(8))", "type": "function", "function": ["name": tool(suffix), "arguments": json]]]], finish: "tool_calls")
        }
        func say(_ text: String) -> Reply { .delta(["role": "assistant", "content": text], finish: "stop") }
        // Cue 自己醒来、什么都没做的一轮最后的话不写（`CueKeeper.Turn.writesReply`）：要让你看到它醒来看到了什么，就用 tell 对你说
        func tell(_ text: String) -> Reply { call("tell", ["text": text]) }

        let last = (request["messages"] as? [[String: Any]])?.last ?? [:]
        let text: String = switch last["content"] {
        case let string as String: string
        case let parts as [[String: Any]]: parts.compactMap { $0["text"] as? String }.joined()
        default: ""
        }
        let sawImage = (last["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "image_url" }
        // 问暗号：从这次请求带着的整段上下文里找你说过的暗号，找不到就是忘了
        if text.contains("暗号是什么") {
            let earlier = (request["messages"] as? [[String: Any]] ?? []).dropLast().map { message -> String in
                switch message["content"] {
                case let string as String: string
                case let parts as [[String: Any]]: parts.compactMap { $0["text"] as? String }.joined()
                default: ""
                }
            }
            return say(earlier.lazy.compactMap { $0.firstMatch(of: /暗号是 (\S+)/)?.1 }.last.map { "记得，暗号是 \($0)" } ?? "不记得暗号")
        }
        if last["role"] as? String == "tool" {
            if text.contains("建好了"), let id = text.firstMatch(of: /（([0-9a-f]{8})）/)?.1 {
                return call("task", ["action": "start", "task": String(id), "model": "fake/fake-model", "effort": "high"])
            }
            finishedAfter.withLock { $0.append(text) }
            return say("办好了")
        }
        if let answer = text.firstMatch(of: /他回答了「.*」：(.+)/)?.1 { return say("知道了：\(answer)") }
        if text.contains("醒来：换了新上下文"), let handoff = text.firstMatch(of: /(交接：.+)/)?.1 { return say("接上了：\(handoff)") }
        if text.contains("memory renew 写交接") { return call("memory", ["action": "renew", "handoff": "交接：在跟登录页"]) }
        if text.contains("请把这张图转给登录页"), let image = text.firstMatch(of: /!\[\]\(cuepad:\/\/img\/[0-9a-f]+\)/)?.0 {
            return call("task", ["action": "say", "task": "修好登录页 转图", "text": "看这张\n\(image)"])
        }
        if sawImage { return say("看到图了") }
        if text.contains("请先查一下") { return .held }
        if text.contains("请对登录页说继续") { return call("task", ["action": "say", "task": "修好登录页 说不出去", "text": "继续"]) }
        if let path = text.firstMatch(of: /请读一下关卡 (\S+)/)?.1 { return call("read", ["path": String(path)]) }
        if text.contains("请建个任务并开工") { return call("task", ["action": "add", "title": "修好登录页", "project": "演示", "body": "把登录页修好"]) }
        if text.contains("请问我一个问题") { return call("tell", ["text": "要推送吗？", "ask": "push", "doing": "推送登录页的修复"]) }
        if last["role"] as? String == "user", let key = failingOnce.first(where: text.contains), once("fail:" + key) { return fail() }
        if text.contains("请慢慢想"), once("hang") { return .hang }
        if text.contains("写回：memory merge") { return tell("记忆合并好了") }
        if text.contains("三步并行"), let board = text.firstMatch(of: /在做 \d+ 件：\n((?:[ -][^\n]*\n)+)/)?.1 {
            return text.contains("醒来：会话有动静") ? tell("看板：\n" + board) : say("看板：\n" + board)
        }
        if text.contains("醒来：会话有动静"), let failed = text.firstMatch(of: /\n- (\[(?:出错|发送失败)[^\]]*\] [^\n]*)/)?.1 {
            return tell("看到了：\(failed)")
        }
        if text.contains("醒来：会话有动静"), text.contains("半路断开"), once("midway") {
            return call("task", ["action": "say", "task": "修好登录页 半路断开", "text": "继续"])
        }
        if text.contains("醒来：会话有动静"), text.contains("要作答") { return tell("去作答了") }
        if text.contains("醒来：会话有动静"), text.contains("[等子代理") { return tell("子代理那边停住了") }
        if text.contains("醒来：会话有动静"), text.contains("请收一下") {
            return call("task", ["action": "done", "task": "修好登录页 请收一下", "evidence": ["登录测试全过"]])
        }
        if text.contains("醒来：会话有动静") {
            if text.contains("先出一次错"), once("error") { return fail() }
            if text.contains("先出两次错"), once("error", times: 2) { return fail() }
            if text.contains("只看看") { return say("只是看了看") }
            return tell("登录页那边歇下了")
        }
        if text.contains("醒来：空闲，例行看一眼") { return tell("巡视了一圈") }
        if text.contains("醒来：刚启用") {
            return asksOnEnable ? call("tell", ["text": "要交给我跟进吗？"]) : say("我看了一眼")
        }
        return say("收到：" + (text.split(separator: "\n").last.map(String.init) ?? ""))
    }
}
#endif
