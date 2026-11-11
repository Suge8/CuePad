#if os(macOS)
import CueTestSupport
import Foundation

/// 托管的 Codex 换成一个 stdio 中转，夹在 CuePad 与真 Codex 之间，管别的线程（子代理）的 `thread/read`；其余原样转发。
/// 真实里是推送先到、`thread/read` 还读不到刚起的线程（负载下实测偶发，见 `CodexRuntime.Owner.unreadable`），或读得慢；
/// 用它把这些先后排定。怎么回由 `mode` 定，随时可改，挂住的读在改成别的之后照新的回：
/// - `whileParentRuns`：主会话的一轮在跑时回错误，这一轮的 `turn/completed` 转出之后照常转发（缺省）。只拦第一次不够：子线程随后的推送会马上再问到。
/// - `fail`：回错误；`hold`：挂住不回；`pass`：照常转发。
/// 另有 `lateStart`：主会话的 `turn/started` 先扣住、`turn/interrupt` 回 -32600，同 `turn/start` 已回、这一轮还没开跑时的真 Codex
/// （0.167.0 实测只有几毫秒，测试排不进去，见 `CodexDriver.interrupt`）；关掉时转出扣住的 `turn/started`，之后的停止照常转发。
@MainActor
final class CodexReadFault {
    enum Mode: String { case whileParentRuns, fail, hold, pass }

    let executable: URL
    private let control: URL

    init(around codex: URL, in directory: URL, mode: Mode = .whileParentRuns) throws {
        control = directory.appending(path: "read-fault", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        executable = directory.appending(path: "codex-read-fault")
        try Self.source(codex: codex, control: control).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        self.mode = mode
        write(mode)
    }

    var mode: Mode {
        didSet { write(mode) }
    }

    var lateStart = false {
        didSet {
            let flag = control.appending(path: "late-start")
            if lateStart { FileManager.default.createFile(atPath: flag.path, contents: nil) } else { try? FileManager.default.removeItem(at: flag) }
        }
    }

    /// `lateStart` 时回了 -32600 的停止有几次
    var refusedStops: Int {
        ((try? String(contentsOf: control.appending(path: "refused.log"), encoding: .utf8)) ?? "").count { $0 == "\n" }
    }

    private func write(_ mode: Mode) { try! Data(mode.rawValue.utf8).write(to: control.appending(path: "mode"), options: .atomic) }

    /// 回过的子线程的读：`fail`、`hold`（挂住）、`pass`，按先后；挂住的放行时再记一笔它怎么回的
    var reads: [(thread: String, outcome: String)] {
        ((try? String(contentsOf: control.appending(path: "reads.log"), encoding: .utf8)) ?? "").split(separator: "\n").map {
            let parts = $0.split(separator: " ")
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// 回成 `outcome` 的子线程有几个
    func threads(_ outcome: String) -> Set<String> { Set(reads.filter { $0.outcome == outcome }.map(\.thread)) }

    private static func source(codex: URL, control: URL) -> String {
        """
        #!/usr/bin/env python3
        import json, os, subprocess, sys, threading, time
        CONTROL = \(String(reflecting: control.path))
        child = subprocess.Popen([\(String(reflecting: codex.path))] + sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        lock, out_lock, in_lock = threading.Lock(), threading.Lock(), threading.Lock()
        own, starts, running, parked, started = set(), set(), set(), [], []
        def late():
            return os.path.exists(CONTROL + "/late-start")
        def mode():
            try:
                return open(CONTROL + "/mode").read().strip()
            except OSError:
                return "\(Mode.whileParentRuns.rawValue)"
        def note(thread, outcome):
            with open(CONTROL + "/reads.log", "a") as log:
                log.write(thread + " " + outcome + "\\n")
        def emit(line):
            with out_lock:
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
        def forward(line):
            with in_lock:
                child.stdin.write(line)
                child.stdin.flush()
        def answer(message, line):
            current, thread = mode(), message["params"]["threadId"]
            if current == "hold":
                parked.append((message, line))
                return note(thread, "hold")
            if current == "pass" or (current == "\(Mode.whileParentRuns.rawValue)" and not running):
                note(thread, "pass")
                return forward(line)
            note(thread, "fail")
            emit((json.dumps({"id": message["id"], "error": {"code": -32603, "message": "injected: unreadable"}}) + "\\n").encode())
        def upstream():
            for line in child.stdout:
                message = json.loads(line)
                with lock:
                    if message.get("id") in starts:
                        own.add(((message.get("result") or {}).get("thread") or {}).get("id"))
                    thread = (message.get("params") or {}).get("threadId")
                    if thread in own and message.get("method") == "turn/started":
                        running.add(thread)
                        if late():
                            started.append(line)
                            continue
                    if thread in own and message.get("method") == "turn/completed":
                        running.discard(thread)
                emit(line)
        def unpark():
            while True:
                time.sleep(0.005)
                with lock:
                    if started and not late():
                        for line in started:
                            emit(line)
                        started[:] = []
                    if parked and mode() != "hold":
                        ready = parked[:]
                        parked[:] = []
                        for message, line in ready:
                            answer(message, line)
        threading.Thread(target=upstream, daemon=True).start()
        threading.Thread(target=unpark, daemon=True).start()
        for line in sys.stdin.buffer:
            message = json.loads(line)
            method = message.get("method")
            with lock:
                if method in ("thread/start", "thread/resume"):
                    starts.add(message["id"])
                elif method == "turn/interrupt" and late():
                    with open(CONTROL + "/refused.log", "a") as log:
                        log.write("\\n")
                    emit((json.dumps({"id": message["id"], "error": {"code": -32600, "message": "no active turn to interrupt"}}) + "\\n").encode())
                    continue
                elif method == "thread/read" and message["params"]["threadId"] not in own:
                    answer(message, line)
                    continue
            forward(line)
        child.stdin.close()
        sys.exit(child.wait())

        """
    }
}
#endif
