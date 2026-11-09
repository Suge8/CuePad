#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

@MainActor
func withScriptedCodex(timing: Timing = noDeadline, _ body: (ScriptedCodex) async throws -> Void) async throws {
    let rig = try ScriptedCodex(timing: timing)
    do {
        try await body(rig)
    } catch {
        await rig.stop()
        throw error
    }
    await rig.stop()
}

/// 一个照指令走的假 `codex app-server`（stdio 上的 python 脚本），真 `CodexRuntime` 连它：托管会话就是它起的进程，终端会话是另起一个当常驻服务。
/// 真 Codex 排不出的先后（子线程的 `thread/read` 读不到、挂住不回、在某一刻放行）由它编排。指令写成控制目录里的文件，按序号执行：
/// `emit` 原样推一条通知（带 `id` 的是服务端请求）；`set` 定某线程的 `thread/read`（ok、fail、hold）与 `thread/turns/list`；`release` 放行挂住的读。
@MainActor
final class ScriptedCodex {
    let root: URL, control: URL, work: URL, script: URL
    let bridge: PiBridge, hooks: AgentHookServer, runtime: CodexRuntime
    private var sequence = 0
    private var daemons: [CodexRPC] = []

    init(timing: Timing) throws {
        root = try makeTempDirectory()
        control = root.appending(path: "control", directoryHint: .isDirectory)
        work = root.appending(path: "work", directoryHint: .isDirectory)
        for directory in [control, work] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        script = root.appending(path: "codex")
        try Self.source.replacingOccurrences(of: "<<CONTROL>>", with: control.path).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let sockets = root.appending(path: "s", directoryHint: .isDirectory)
        let paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: ["HOME": root.path, "PATH": Self.path])
        hooks = AgentHookServer(path: paths.pi.hookSocket)
        bridge = PiBridge(socketDirectory: sockets)
        let script = script, locator = ExecutableLocator(searchDirectories: [URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
        runtime = CodexRuntime(bridge: bridge, paths: paths, hooks: hooks, codex: { script }, locate: { locator }, presence: TestPresence(), timing: timing)
        try bridge.start()
        try runtime.start()
    }

    func stop() async {
        await runtime.stop()()
        for daemon in daemons { await daemon.shutdown() }
        hooks.stop()
        bridge.stop()
        await TestProcesses.stop(under: [root])
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 指令

    private func send(_ command: [String: Any]) {
        sequence += 1
        let data = try! JSONSerialization.data(withJSONObject: command)
        try! data.write(to: control.appending(path: String(format: "cmd-%06d.json", sequence)), options: .atomic)
    }

    func emit(_ method: String, _ params: [String: Any], id: Int? = nil) {
        send(["op": "emit", "method": method, "params": params].merging(id.map { ["id": $0] } ?? [:]) { $1 })
    }

    func set(_ thread: String, read: String? = nil, info: [String: Any]? = nil, turns: [[String: Any]]? = nil) {
        var command: [String: Any] = ["op": "set", "thread": thread]
        if let read { command["read"] = read }
        if let info { command["info"] = info }
        if let turns { command["turns"] = turns }
        send(command)
    }

    func release(_ thread: String) { send(["op": "release", "thread": thread]) }

    /// 此前发的指令都已执行
    func sync() async throws {
        let mark = "ping\(sequence + 1)"
        send(["op": "ping", "thread": mark])
        try await eventually("假进程执行了指令") { self.requests.contains("ctl:ping \(mark)") }
    }

    /// 假进程收到的请求与执行过的指令，按到达先后
    var requests: [String] {
        ((try? String(contentsOf: control.appending(path: "requests.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    func reads(_ thread: String) -> Int { requests.filter { $0 == "thread/read \(thread)" }.count }
    var turnStarts: Int { requests.filter { $0.hasPrefix("turn/start") }.count }

    // MARK: 线程与一轮

    static func child(_ id: String, name: String = "fruit", parent: String = "main") -> [String: Any] {
        ["id": id, "parentThreadId": parent, "agentRole": "default", "cwd": "/", "createdAt": 1.0, "updatedAt": 2.0,
         "source": ["subAgent": ["thread_spawn": ["agent_path": "/root/\(name)"]]]]
    }

    static func turn(_ status: String) -> [String: Any] { ["id": "ct", "status": status] }

    /// 子线程 `id`：第一条推送读不到（暂时读不到），之后的读挂住，等 `release`
    func childUnreadableThenHeld(_ id: String, name: String = "fruit", pid: Int32) async throws {
        set(id, read: "fail", info: Self.child(id, name: name), turns: [Self.turn("inProgress")])
        childStarted(id)
        try await eventually("\(id) 暂时读不到") { self.owner(id, pid) == "unreadable" }
        set(id, read: "hold")
        try await sync()
    }

    func parentStarted(_ turn: String = "t1") { emit("turn/started", ["threadId": "main", "turn": ["id": turn]]) }
    func parentCompleted(_ turn: String = "t1") { emit("turn/completed", ["threadId": "main", "turn": ["id": turn, "status": "completed"]]) }
    func childStarted(_ id: String, turn: String = "ct") { emit("turn/started", ["threadId": id, "turn": ["id": turn]]) }
    func childCompleted(_ id: String, turn: String = "ct") { emit("turn/completed", ["threadId": id, "turn": ["id": turn, "status": "completed"]]) }

    // MARK: 会话

    /// CuePad 开的托管会话，主线程是 `main`，这一轮已在跑
    func openRunning() async throws -> (id: PiSession.ID, pid: Int32) {
        let id = try await runtime.open(in: work, launchToken: "t", name: nil, model: nil, thinking: nil)
        parentStarted()
        try await eventually("在跑") { self.state(id) == .thinking }
        return (id, Int32(id.split(separator: ".").last!)!)
    }

    /// 终端会话：另起一个假进程当常驻服务（没有托管的驱动）
    func attachTerminal() async throws -> (session: CodexRuntime.Tracked, pid: Int32) {
        let info: [String: Any] = ["id": "main", "cwd": work.path, "preview": "hi"]
        let rpc = try await CodexRPC.launch(script, environment: ["PATH": Self.path])
        daemons.append(rpc)
        set("main", info: info)
        try await sync()
        let pid = rpc.pid
        rpc.onNotification = { [weak runtime] method, params in runtime?.notification(method, params, from: pid) }
        runtime.daemon = rpc
        runtime.attach(runtime.makeSession(JSONValue.parse(try JSONSerialization.data(withJSONObject: info))!, pid: pid))
        return (runtime.tracked["main.\(pid)"]!, pid)
    }

    func state(_ id: PiSession.ID) -> PiWorkState? { bridge.session(id: id)?.state }
    func roster(_ id: PiSession.ID) -> [String] { bridge.session(id: id)?.subagents.map(\.name) ?? [] }

    func owner(_ thread: String, _ pid: Int32) -> String {
        switch runtime.threads["\(thread).\(pid)"] {
        case .asking: "asking"
        case .unreadable: "unreadable"
        case .session: "session"
        case .foreign: "foreign"
        case nil: "nil"
        }
    }

    private static let path = "/usr/bin:/bin"

    private static let source = #"""
        #!/usr/bin/env python3
        import json, os, sys, threading, time
        CONTROL = "<<CONTROL>>"
        out_lock = threading.Lock()
        lock = threading.RLock()
        world = {}
        parked = []
        starts = [0]

        def out(m):
            with out_lock:
                sys.stdout.write(json.dumps(m) + "\n")
                sys.stdout.flush()

        def note(line):
            with open(CONTROL + "/requests.log", "a") as f:
                f.write(line + "\n")

        def error(rid, text):
            out({"id": rid, "error": {"code": -32603, "message": text}})

        def answer_read(rid, thread):
            with lock:
                w = world.get(thread)
                if not w or not w.get("info"):
                    return error(rid, "no such thread")
                if w.get("read") == "hold":
                    parked.append((rid, thread))
                    return
                if w.get("read") == "fail":
                    return error(rid, "injected: not readable")
                out({"id": rid, "result": {"thread": w["info"]}})

        def request(m):
            rid, method, p = m["id"], m["method"], m.get("params") or {}
            thread = p.get("threadId")
            note(method + (" " + thread if thread else ""))
            if method == "initialize":
                out({"id": rid, "result": {}})
            elif method == "thread/start":
                with lock:
                    main = world.setdefault("main", {"read": "ok", "info": {"id": "main", "cwd": p.get("cwd", "/"), "preview": "hi"}})
                out({"id": rid, "result": {"thread": main["info"]}})
            elif method == "thread/read":
                answer_read(rid, thread)
            elif method == "thread/turns/list":
                with lock:
                    turns = (world.get(thread) or {}).get("turns", [])
                out({"id": rid, "result": {"data": turns[:1]}})
            elif method == "config/read":
                out({"id": rid, "result": {"origins": {"sandbox_mode": {}}}})
            elif method in ("skills/list", "model/list"):
                out({"id": rid, "result": {"data": []}})
            elif method == "turn/start":
                starts[0] += 1
                out({"id": rid, "result": {"turn": {"id": "w%d" % starts[0]}}})
            else:
                error(rid, "unsupported " + method)

        def poll():
            while True:
                for name in sorted(os.listdir(CONTROL)):
                    if not (name.startswith("cmd-") and name.endswith(".json")):
                        continue
                    path = CONTROL + "/" + name
                    try:
                        cmd = json.load(open(path))
                    except Exception:
                        continue
                    os.remove(path)
                    op = cmd["op"]
                    with lock:
                        if op == "emit":
                            message = {"method": cmd["method"], "params": cmd["params"]}
                            if "id" in cmd:
                                message["id"] = cmd["id"]
                            out(message)
                        elif op == "set":
                            w = world.setdefault(cmd["thread"], {"read": "ok"})
                            for k in ("info", "read", "turns"):
                                if k in cmd:
                                    w[k] = cmd[k]
                        elif op == "release":
                            ready = [(r, t) for (r, t) in parked if t == cmd["thread"]]
                            parked[:] = [(r, t) for (r, t) in parked if t != cmd["thread"]]
                            for r, t in ready:
                                answer_read(r, t)
                    note("ctl:" + op + (" " + cmd["thread"] if "thread" in cmd else ""))
                time.sleep(0.003)

        threading.Thread(target=poll, daemon=True).start()
        for line in sys.stdin:
            m = json.loads(line)
            if "id" in m and "method" in m:
                request(m)
        """#
}
#endif
