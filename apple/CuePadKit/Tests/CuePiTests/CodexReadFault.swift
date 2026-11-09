#if os(macOS)
import Foundation

/// 托管的 Codex 换成一个 stdio 中转：主会话的一轮在跑时，别的线程（子代理）的 `thread/read` 由中转回错误、不转给 Codex；
/// 这一轮的 `turn/completed` 转出之后才照常转发。造出“这一轮要歇下时子线程还认不出来”：真实里是推送先到、`thread/read` 还读不到刚起的线程
/// （负载下实测偶发，见 `CodexRuntime.Owner.unreadable`），之后又没有新推送来再问。只拦第一次不够：子线程随后的推送会马上再问到。
enum CodexReadFault {
    static func wrapper(around codex: URL, in directory: URL) throws -> URL {
        let script = directory.appending(path: "codex-read-fault")
        try """
            #!/usr/bin/env python3
            import json, subprocess, sys, threading
            child = subprocess.Popen([\(String(reflecting: codex.path))] + sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            lock, own, starts, running = threading.Lock(), set(), set(), set()
            def emit(line):
                with lock:
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()
            def upstream():
                for line in child.stdout:
                    message = json.loads(line)
                    if message.get("id") in starts:
                        thread = (message.get("result") or {}).get("thread") or {}
                        own.add(thread.get("id"))
                    thread = (message.get("params") or {}).get("threadId")
                    if thread in own and message.get("method") == "turn/started":
                        running.add(thread)
                    if thread in own and message.get("method") == "turn/completed":
                        running.discard(thread)
                    emit(line)
            threading.Thread(target=upstream, daemon=True).start()
            for line in sys.stdin.buffer:
                message = json.loads(line)
                method = message.get("method")
                if method in ("thread/start", "thread/resume"):
                    starts.add(message["id"])
                elif method == "thread/read" and running and message["params"]["threadId"] not in own:
                    emit((json.dumps({"id": message["id"], "error": {"code": -32603, "message": "injected: unreadable while the parent runs"}}) + "\\n").encode())
                    continue
                child.stdin.write(line)
                child.stdin.flush()
            child.stdin.close()
            sys.exit(child.wait())

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
#endif
