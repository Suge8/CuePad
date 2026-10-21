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

extension CueHostTests {
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
                restarts: [.milliseconds(200), .milliseconds(200), .milliseconds(200)], retryWake: .seconds(1), sayWait: 5, quietHours: [])
            let launch = CuePad.CueLaunch(executable: realPi, path: realPi.deletingLastPathComponent().path + ":/usr/bin:/bin", agents: [])
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
            try await app.syncs()
            if let claude {
                try await claude.enable(self)
                return
            }
            try await app.services.enableCue(on: TestApp.hostID, moving: false)
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

        func say(_ text: String) async throws { try await store.addCueMessage(.you, text: text) }

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
}
#endif
