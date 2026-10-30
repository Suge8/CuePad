#if os(macOS)
@testable import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

/// #43：Grok 的磁盘登记不是当前进程的会话身份证明；复用 PID 不能让旧历史重新获得运行确认。
struct RuntimeGrokTests {
    @Test func 旧登记与旧轮次不签运行证明_当前进程关联与新报告才接入() async throws {
        let app = TestApp(), store = app.services.store, workspace = Workspace(services: app.services)
        let paths = AgentPaths(pi: app.piPaths, environment: app.agentHomes)
        let home = paths.home(of: .grok)
        let executable = URL(filePath: "/usr/bin/tail")
        func history(_ id: String) throws -> URL {
            let file = GrokRuntime.sessionFile(in: home, cwd: app.directory.path, id: id)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let line: [String: Any] = ["timestamp": Date.now.timeIntervalSince1970, "method": "session/update", "params": [
                "sessionId": id, "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "继续检查"]],
            ]]
            var bytes = try JSONSerialization.data(withJSONObject: line)
            bytes.append(0x0A)
            try bytes.write(to: file)
            return file
        }
        let staleFile = try history("stale")
        let liveFile = try history("live"), otherFile = try history("other")
        let unrelated = try await ChildProcess(URL(filePath: "/bin/cat"), [], placement: .group, input: .pipe)
        defer { unrelated.end(grace: .zero) }
        let wrongSession = try await ChildProcess(executable, ["-f", otherFile.path], placement: .group, output: .lines)
        defer { wrongSession.end(grace: .zero) }
        var otherOutput = wrongSession.output.makeAsyncIterator()
        _ = try #require(await otherOutput.next(), "只读替身没有打开会话文件：\(wrongSession.stderrTail)")
        let current = try await ChildProcess(executable, ["-f", liveFile.path], placement: .group, output: .lines)
        defer { current.end(grace: .zero) }
        var output = current.output.makeAsyncIterator()
        _ = try #require(await output.next(), "只读替身没有打开会话文件：\(current.stderrTail)")
        let oldRound = try await ChildProcess(executable, ["-f", staleFile.path], placement: .group, output: .lines)
        defer { oldRound.end(grace: .zero) }
        var oldOutput = oldRound.output.makeAsyncIterator()
        _ = try #require(await oldOutput.next())
        _ = try history("live")
        try append("available_commands_update", session: "stale", file: staleFile)
        let task = try await workspace.createTask("关机前的工作", in: Project.defaultID)
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID, boot: "old-boot")
        try await recorder.update(sessionID: "stale", state: .compacting, title: "关机前的工作", agent: .grok)
        try await store.bindSession("stale", to: task.id)
        try await store.recordMacPresence(host: TestApp.hostID) { true }
        let entries: [[String: Any]] = [
            ["session_id": "stale", "pid": unrelated.pid, "cwd": app.directory.path],
            ["session_id": "stale", "pid": wrongSession.pid, "pid_start": try #require(PiProcess.running(pid: wrongSession.pid)).startedAt - 1, "cwd": app.directory.path],
            ["session_id": "stale", "pid": oldRound.pid, "pid_start": try #require(PiProcess.running(pid: oldRound.pid)).startedAt, "cwd": app.directory.path],
            ["session_id": "live", "pid": current.pid, "pid_start": try #require(PiProcess.running(pid: current.pid)).startedAt, "cwd": app.directory.path],
        ]
        try JSONSerialization.data(withJSONObject: entries).write(to: home.appending(path: "active_sessions.json"))
        let events = app.pi.changes()
        let consume = Task { try await app.services.consumePiChanges(events) }
        defer { consume.cancel() }
        let runtime = GrokRuntime(bridge: app.pi, paths: paths, files: store.files, grok: { executable })
        defer { _ = runtime.stop() }
        try runtime.start()
        runtime.follow(.sessions(["stale", "live"]))
        _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["live"])["live"]?.state }) { $0?.runtimeState.isWorking == true }
        #expect(app.pi.sessions.map(\.sessionID) == ["live"])
        let stale = try #require(try await store.piSessions(sessionIDs: ["stale"])["stale"]?.state)
        #expect(stale.state == .known(.compacting) && stale.bootID == "old-boot")
        #expect(try await !store.runtimeIsConfirmed(stale))
        #expect(workspace.shown(stale, delivery: nil).status == .unknown)
        let summary = CueNow(try await CueDigest.read(from: store), at: .always(), local: .init(waiting: nil, here: nil))
        #expect(summary.tally.moving == 1)
        let live = try #require(app.pi.session(sessionID: "live"))
        #expect(live.capabilities == [])
        await #expect(throws: PiBridgeError.self) { try await app.pi.send(PiMessage(text: "不应交出"), to: live.id) }
        func append(_ kind: String, session: String, file: URL) throws {
            let update: [String: Any] = kind == "user_message_chunk"
                ? ["sessionUpdate": kind, "content": ["type": "text", "text": "现在继续"]] : ["sessionUpdate": kind]
            let row: [String: Any] = ["timestamp": Date.now.timeIntervalSince1970, "method": "session/update", "params": ["sessionId": session, "update": update]]
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var bytes = try JSONSerialization.data(withJSONObject: row)
            bytes.append(0x0A)
            try handle.write(contentsOf: bytes)
        }
        try append("turn_completed", session: "stale", file: staleFile)
        try append("user_message_chunk", session: "stale", file: staleFile)
        _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["stale"])["stale"]?.state }) { $0?.runtimeState.isWorking == true }
        #expect(app.pi.session(sessionID: "stale")?.pid == oldRound.pid)
        try append("turn_completed", session: "live", file: liveFile)
        runtime.read(try PiHistory.index(file: liveFile, agent: .grok, from: nil, files: store.files))
        _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["live"])["live"]?.state }) { $0?.runtimeState == .known(.settled) }
        let retained = entries.filter { $0["session_id"] as? String != "live" }
        try JSONSerialization.data(withJSONObject: retained).write(to: home.appending(path: "active_sessions.json"), options: .atomic)
        _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["live"])["live"]?.state }) { $0?.state == .known(.ended) }
        #expect(app.pi.session(sessionID: "live") == nil)
        consume.cancel()
        _ = await consume.result
        await runtime.stop()()
        for process in [unrelated, wrongSession, oldRound, current] { process.end(grace: .zero); _ = await process.waitForExit() }
    }
}
#endif
