#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CuePad

extension CueHostTests {
    /// 起大脑的门（`Rig.launches`）：起大脑在主线程之外问它，所以用锁。
    nonisolated final class LaunchGate: Sendable {
        private let state = Mutex((open: true, attempts: 0, elsewhere: (@Sendable () -> Void)?.none))
        var attempts: Int { state.withLock { $0.attempts } }
        func set(open: Bool) { state.withLock { $0.open = open } }

        func pass(_ launch: CuePad.CueLaunch) -> CuePad.CueLaunch? {
            state.withLock { state in
                state.attempts += 1
                return state.open ? launch : nil
            }
        }

        /// 下一次试起别家（这台 Mac 上找不到、起不来）时先做 `action`，只做一次：在对账途中让什么发生（如钟走过某一刻）。
        func whenTryingElsewhere(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.elsewhere = action } }

        func passElsewhere() -> CuePad.CueLaunch? {
            state.withLock { state in
                defer { state.elsewhere = nil }
                return state.elsewhere
            }?()
            return nil
        }
    }

    /// Rig 的钟：App 的钟（`app`：资料库、会话状态的写入节流、Cue 的对账定时器都走它）与看门狗的钟（`CueTiming.awake`）。
    /// 要等的时限不真等，跳过去；起大脑在主线程之外，所以也能在那里跳（`LaunchGate.whenTryingElsewhere`）。
    nonisolated final class Clocks: Sendable {
        let app = JumpTiming()
        /// 看门狗的钟醒着跳过的；像 Mac 合盖那样跳过的不算
        private let awakeSkipped = Mutex(Duration.zero)

        func awake() -> SuspendingClock.Instant { SuspendingClock.now.advanced(by: awakeSkipped.withLock { $0 }) }

        /// 往前跳 `duration`：两个钟一起跳；`asleep` 像 Mac 合盖的那一段，看门狗的钟不走。
        func jump(by duration: Duration, asleep: Bool = false) {
            if !asleep { awakeSkipped.withLock { $0 += duration } }
            app.jump(by: duration)
        }

        /// 醒着跳到 `date`；已经过了就不动。
        func jump(to date: Date) {
            let ahead = date.timeIntervalSince(app.now)
            if ahead > 0 { jump(by: .seconds(ahead)) }
        }
    }

    final class Rig {
        let model: FakeModel
        let notifier = RecordingCueNotifier()
        /// 起 Pi 的大脑要过的门：关上时这台 Mac 找不到 Pi（起不来），数着试了几次
        let launches = LaunchGate()
        let app: TestApp
        let clocks = Clocks()
        var clock: JumpTiming { clocks.app }
        let folder: URL
        /// 真大脑的临时目录（`EvalBrain.launch`，开销记录在里面）；假模型时为 nil
        let brainDirectory: URL?
        var services: AppServices { app.services }
        var store: CueStore { services.store }

        /// `failingOnce`：信封里有这些话的请求，假模型第一次报错。
        /// `seesImages`：假模型能不能看图（Pi 的模型表里写的输入）。`asksOnEnable`：刚启用那一轮（手上有事才有，`prepare` 摆）先用 tell 问你一句，再写最后的回复。
        /// `brain`：大脑换成真的 Agent（`CueEvalTests`），假模型的剧本不再用上。`standby`：照常用假模型的 Pi 启用，这台 Mac 上那一家（不是 Pi）
        /// 起的是真的 Agent，换大脑换过去就是它（`CueEvalFailoverTests`）。`patrolAfter`：空闲多久巡视一次；
        /// `cacheLifetime`：提示缓存算多久过期；`renewAt`：换新线。`clock`：信封上写的此刻。`timing`：再改别的时间规则（重起、看门狗、热巡视）。
        /// `prepare`：启用 Cue 之前在库里摆好的（多日评测预置的历史）。`settleGate`：Pi 的大脑多加载收尾闸（`armSettle`）。
        init(
            usage: Int = 100, failingOnce: [String] = [], seesImages: Bool = true, asksOnEnable: Bool = false, brain: EvalBrain? = nil, standby: EvalBrain? = nil,
            settleGate: Bool = false,
            patrolAfter: Duration = .seconds(3600), cacheLifetime: Duration = .seconds(3600),
            renewAt: Int = CueContext.renewAt, clock: @escaping @Sendable () -> Date = { .now }, timing tune: (inout CueTiming) -> Void = { _ in },
            prepare: ((Rig) async throws -> Void)? = nil
        ) async throws {
            model = try FakeModel(usage: usage, failingOnce: failingOnce, asksOnEnable: asksOnEnable)
            let port = try await model.start()
            var timing = CueTiming(
                patrolAfter: patrolAfter, cacheLifetime: cacheLifetime, renewAt: renewAt,
                restarts: [.milliseconds(200), .milliseconds(200), .milliseconds(200)], retryWake: .seconds(1), sayWait: 5, quietHours: [], clock: clock)
            let clocks = clocks
            timing.awake = { clocks.awake() }
            tune(&timing)
            let launch = CuePad.CueLaunch(
                executable: settleGate ? try Self.gatedPi() : realPi, path: realPi.deletingLastPathComponent().path + ":/usr/bin:/bin", agents: [])
            let real = brain ?? standby
            let directory = real.map { _ in TestLibraries.makeDirectory() }
            brainDirectory = directory
            let brainLaunch = try real.map { try $0.launch(in: directory!) }, runtime = real?.runtime, gate = launches
            app = TestApp(cue: CueDependencies(
                launch: { agent, _ in agent == runtime ? brainLaunch : agent == .pi ? gate.pass(launch) : gate.passElsewhere() },
                helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/cuepad"), notifier: notifier, timing: timing),
                timing: clocks.app.timing)
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
            try await app.syncs()
            try await prepare?(self)
            if let brain {
                try await brain.enable(self)
            } else {
                try await app.services.enableCue(on: TestApp.hostID, moving: false)
            }
            // 值班起来、对过刚启用这一步：手上有事的（`prepare` 摆了）这时醒来看一眼，用例自己等它说的话
            try await eventually("刚启用对过账") { self.services.cue.keeper?.progress.greeted != nil }
        }

        /// 启用前手上已有一件没开工的事：刚启用时 Cue 醒来看一眼。
        static func handOverWork(_ rig: Rig) async throws {
            let project = try #require(try await rig.store.projects().first { $0.name == "演示" })
            _ = try await rig.store.createTask("整理周报", in: project.id)
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
            // 开出来的会话一上桥就记成歇着：先等这一轮的在干活写进库，回复才不会早于这一轮的开始（早了不算读到回答，Cue 不醒）
            session.setState(["kind": "thinking"])
            try await eventually("在干活写进库") { try await self.store.sessions(matching: session.sessionID).first?.state.isWorking == true }
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

        func say(_ text: String) async throws { try await store.addCueMessage(.you, text: text) }

        func jump(by duration: Duration, asleep: Bool = false) { clocks.jump(by: duration, asleep: asleep) }
        func jump(to date: Date) { clocks.jump(to: date) }

        /// 出错后等着重来、起不来等着重起：跳到那一刻（`Setback.retryAt`、`Phase.restarting`），退避不真等。还没排上就不动。
        func skipBackoff() {
            guard let keeper = services.cue.keeper else { return }
            var due = keeper.setback?.retryAt
            if case .restarting(_, _, let at) = keeper.phase { due = [due, at].compactMap(\.self).min() }
            if let due { jump(to: due) }
        }

        /// 一轮在跑、大脑一直没动静：跳过看门狗剩下的时长。从最后一次大脑事件算：挂住之后才到的事件会重新算起，所以每次都按剩下的跳。
        func skipSilence() {
            guard let keeper = services.cue.keeper, keeper.turn != nil else { return }
            let left = keeper.setup.timing.silence - (clocks.awake() - keeper.heardAt)
            if left > .zero { jump(by: left) }
        }

        /// 叫值班的管理器对账，等它对完、重新睡下（对账的定时器换了一个）：负向断言前让它看过此刻的库与钟。
        /// 叫两次：第一次等到的可能是叫它时已经在对的那一次，第二次等到的一定是那之后开始的。
        /// 要有排着的时刻（定时、巡视、重来、看门狗……）：什么都没排时它不睡，这里等不到。
        func reconciled() async throws {
            let keeper = try #require(services.cue.keeper)
            for _ in 0..<2 {
                let before = keeper.timer
                keeper.input.yield(.kick)
                try await eventually("对过账、重新睡下") { keeper.timer != nil && keeper.timer != before }
            }
        }

        /// 在 Cue 页的选择器里选 Pi 的这个模型与强度（`AppServices.updateCue`），等值班的大脑用上。
        func chose(model: String, effort: PiThinkingLevel) async throws {
            try await services.updateCue {
                $0.model = model
                $0.effort = .known(effort)
            }
            try await eventually("大脑用上了选的模型") { self.health?.model == model }
        }

        /// 起 Pi 时多带收尾闸扩展（`settle-gate.ts`）、交给它的每一行另记一份（`handed`）的启动脚本。
        private static func gatedPi() throws -> URL {
            let gate = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "CuePadKit/Tests/CuePiTests/Fixtures/settle-gate.ts")
            let script = TestLibraries.makeDirectory().appending(path: "pi")
            try """
                #!/bin/sh
                mkdir -p "$PI_CODING_AGENT_DIR/settle-gate"
                tee -a "$PI_CODING_AGENT_DIR/settle-gate/stdin.log" | '\(realPi.path)' "$@" -e '\(gate.path)'

                """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return script
        }

        private var settleGate: URL { app.piPaths.agentDirectory.appending(path: "settle-gate", directoryHint: .isDirectory) }

        /// Pi 下一次收尾时停在报出来之前（`settle-gate.ts`），返回等它停住的那一下；`releaseSettle` 放行。
        func armSettle() throws -> () async throws -> Void {
            try FileManager.default.createDirectory(at: settleGate, withIntermediateDirectories: true)
            try Data().write(to: settleGate.appending(path: "arm"))
            return { [settleGate] in
                try await eventually("Pi 收尾停住") { FileManager.default.fileExists(atPath: settleGate.appending(path: "held").path) }
            }
        }

        /// 放行停住的收尾，等它放行；到了上限才放行（没看到 release）的算失败。
        func releaseSettle() async throws {
            let gate = settleGate
            try Data().write(to: gate.appending(path: "release"))
            func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: gate.appending(path: name).path) }
            try await eventually("收尾闸放行") { exists("released") || exists("ceiling") }
            #expect(!exists("ceiling"), "收尾闸到了上限才放行：没看到 release")
        }

        /// 含 `text` 的那一行交到了 Pi（收尾闸停着时 Pi 先收下、等报完收尾再处理）。
        func handed(_ text: String) async throws {
            try await eventually("「\(text)」交到 Pi") { self.handings(of: text) > 0 }
        }

        /// 含 `text` 的行交到 Pi 几次（各个班次的大脑合起来）。
        func handings(of text: String) -> Int {
            let log = settleGate.appending(path: "stdin.log")
            return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count { $0.contains(text) }
        }

        /// 另一台 Mac（mac-b）醒着、它的在线记录同步到了这里：它上面的会话这才算在跑，Cue 才能对它说话（`CueStore.runtimeIsConfirmed`）。
        /// 返回替那台 Mac 写会话状态的记录器。
        func remoteMac() async throws -> PiStateRecorder { try await app.runtimeRecorder(on: "mac-b") }

        /// 这个 Rig 的值班管理器写下的大脑健康（`CueHealth`）。
        var health: CueHealth? { CueHealth.read(library: app.directory.appending(path: "Library")) }

        /// Cue 写的、含 `text` 的消息有几条。
        func count(_ text: String) async throws -> Int {
            try await store.cueMessages().count { $0.author == .known(.cue) && $0.text.contains(text) }
        }

        func image() throws -> String { CueFormat.imageMarkup(key: try store.files.store(pngData(shade: 0.5))) }

        /// 等到出现一条 `author` 写的、含 `text` 的消息（中间隔着真 Pi 大脑起进程、读剧本）。
        /// `skippingBackoff`：等的途中跳过出错后的重来、起不来后的重起（`skipBackoff`）。
        @discardableResult
        func message(_ author: CueAuthor, containing text: String, skippingBackoff: Bool = false) async throws -> CueMessage {
            var found: CueMessage?
            try await eventually("\(author) 说「\(text)」") {
                if skippingBackoff { self.skipBackoff() }
                found = try await self.store.cueMessages().last { $0.author == .known(author) && $0.text.contains(text) }
                return found != nil
            }
            return found!
        }

        /// 这个 Rig 的 Cue 的大脑：工作目录是这个库的 Cue 工作目录的进程（别的测试也在起 Pi）里，父进程不在其中的那个
        /// （大脑起的工具服务也在这个目录）。在全部进程里找：CuePad 起的进程经中转挂到 launchd 下（`ChildProcess`），不是测试进程的子进程。
        var brainPIDs: [pid_t] {
            let inWork = workPIDs
            return inWork.filter { !inWork.contains(Self.parent(of: $0)) }
        }

        /// 大脑起的 Cue 的工具服务（`cuepad mcp`）：父进程是大脑的那个 cuepad。
        var toolServerPIDs: [pid_t] {
            let brains = brainPIDs
            return workPIDs.filter { pid in
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard brains.contains(Self.parent(of: pid)), proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
                return URL(filePath: String(cString: path)).lastPathComponent == "cuepad"
            }
        }

        private static func parent(of pid: pid_t) -> pid_t {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return 0 }
            return pid_t(info.pbi_ppid)
        }

        /// 工作目录是这个库的 Cue 工作目录的进程。
        private var workPIDs: [pid_t] {
            let work = app.directory.appending(path: "Library/Cue/work").resolvingSymlinksInPath().path
            var pids = [pid_t](repeating: 0, count: 8192)
            let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
            return pids.prefix(max(0, count)).filter { pid in
                guard pid > 0 else { return false }
                var info = proc_vnodepathinfo()
                guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return false }
                let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return URL(filePath: cwd).resolvingSymlinksInPath().path == work
            }
        }
    }
}
#endif
