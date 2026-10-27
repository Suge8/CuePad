#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
@testable import CuePi

extension AgentTape {
    func startControl() throws {
        let fd = try UnixSocket.listen(control)
        controlSource = UnixSocket.accept(fd) { [self] client in
            Thread.detachNewThread { [self] in serveStub(client) }
        }
    }

    /// 一个替身连上来：读它的命令行与环境，录制时起真 Agent 接上，回放时认领录像带里的这次启动。
    private func serveStub(_ fd: Int32) {
        let reader = LineReader(fd: fd)
        var name = "", pid: Int32 = 0, cwd = "", arguments: [String] = [], environment: [String: String] = [:]
        header: while let line = reader.next() {
            let (kind, value) = Self.split(line)
            let decoded = String(decoding: Data(base64Encoded: value) ?? Data(), as: UTF8.self)
            switch kind {
            case "n": name = decoded
            case "p": pid = Int32(value) ?? 0
            case "w": cwd = decoded
            case "a": arguments.append(decoded)
            case "v": if let eq = decoded.firstIndex(of: "=") { environment[String(decoded[..<eq])] = String(decoded[decoded.index(after: eq)...]) }
            case "h": break header
            default: break
            }
        }
        let stub = Stub(fd: fd, pid: pid)
        switch mode {
        case .record, .live: recordProcess(stub, reader, name: name, arguments: arguments, cwd: cwd, environment: environment)
        case .replay: replayProcess(stub, reader, name: name, arguments: arguments, cwd: cwd, mark: environment[HostMark.variable])
        }
    }

    private func recordProcess(_ stub: Stub, _ reader: LineReader, name: String, arguments: [String], cwd: String, environment: [String: String]) {
        guard let real = Self.realExecutables[name] ?? nil else {
            stub.send("r " + Data("录像带：没有真的 \(name)\n".utf8).base64EncodedString())
            return stub.send("x 127")
        }
        if !state.withLock({ state in defer { state.proxying = true }; return state.proxying }) {
            try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? startHookProxy()
        }
        var environment = environment
        let channel = state.withLock { state in
            state.processCount += 1
            state.secrets += environment.filter { key, value in
                ["KEY", "TOKEN", "SECRET", "PASSWORD"].contains { key.uppercased().contains($0) } && value.count >= 8
            }.map(\.value)
            if let outer = environment["CUEPAD_PI_SOCKET_DIR"] { state.outerSockets = outer }
            return "p\(state.processCount)"
        }
        if let outer = environment["CUEPAD_PI_SOCKET_DIR"] {
            var info = stat()
            chmod(inner.path, lstat(outer, &info) == 0 ? info.st_mode & 0o777 : 0o700)
            environment["CUEPAD_PI_SOCKET_DIR"] = inner.path
        }
        // agent 目录在本用例临时目录里的 Pi 用的是假模型：录制时不联网（Pi 只认这个环境变量与 --offline，没有设置项）。大脑用用户自己的 agent 目录与真模型，不加
        if name == "pi", environment["PI_CODING_AGENT_DIR"]?.hasPrefix(state.withLock({ $0.temporaryRoot })) == true { environment["PI_OFFLINE"] = "1" }
        if name == "grok" { environment.merge(GrokModel.environment) { current, _ in current } }
        environment["PATH"] = ((environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != bin.path }
            + [real.deletingLastPathComponent().path]).joined(separator: ":")
        record(TapeEvent(k: "spawn", c: channel, d: name, p: cwd, a: arguments, m: environment[HostMark.variable]))
        /// 只有测试读它的标准输出、且只读这几类事件（`PiProcess`）：别的行照样交出去，不录
        let kept = environment.removeValue(forKey: Self.stdoutTypesVariable).map { Set($0.split(separator: ",").map(String.init)) }
        guard let process = try? RealProcess(real, arguments, cwd: cwd, environment: environment) else {
            record(TapeEvent(k: "exit", c: channel, n: 127))
            return stub.send("x 127")
        }
        state.withLock { state in
            state.realToStub[process.pid] = stub.pid
            state.stubPids[channel] = stub.pid
            state.realGroups.append(process.pid)
            state.stubs[channel] = stub
        }
        let outputs = DispatchGroup()
        for (fd, kind, prefix) in [(process.stdout, "stdout", "o"), (process.stderr, "stderr", "r")] {
            outputs.enter()
            Thread.detachNewThread { [self] in
                var lines = LineSplitter()
                func forward(_ line: Data, newline: Bool) {
                    let text = rewriteForCuePad(String(decoding: line, as: UTF8.self))
                    if kind == "stderr" || kept.map({ Self.type(of: text).map($0.contains) ?? false }) ?? true {
                        record(TapeEvent(k: kind, c: channel, d: text))
                    }
                    stub.send(prefix + " " + Data((text + (newline ? "\n" : "")).utf8).base64EncodedString())
                }
                UnixSocket.read(fd) { chunk in for line in lines.append(chunk) { forward(line, newline: true) } }
                if let rest = lines.flush() { forward(rest, newline: false) }
                close(fd)
                outputs.leave()
            }
        }
        Thread.detachNewThread { [self] in
            let status = process.wait()
            _ = outputs.wait(timeout: .now() + 2)
            let signaled = status & 0x7F != 0
            let code = signaled ? -Int(status & 0x7F) : Int((status >> 8) & 0xFF)
            record(TapeEvent(k: "exit", c: channel, n: code))
            stub.told = true
            stub.send(signaled ? "k \(-code)" : "x \(code)")
        }
        var lines = LineSplitter()
        while let line = reader.next() {
            let (kind, value) = Self.split(line)
            switch kind {
            case "i":
                let data = Data(base64Encoded: value) ?? Data()
                for line in lines.append(data) { record(TapeEvent(k: "stdin", c: channel, d: String(decoding: line, as: UTF8.self))) }
                _ = UnixSocket.writeAll(process.stdin, data)
            case "e":
                if let rest = lines.flush() { record(TapeEvent(k: "stdin", c: channel, d: String(decoding: rest, as: UTF8.self))) }
                record(TapeEvent(k: "eof", c: channel))
                process.closeInput()
            case "s":
                record(TapeEvent(k: "signal", c: channel, n: Int(value) ?? 0))
                kill(process.pid, Int32(value) ?? SIGTERM)
            default: break
            }
        }
        if !stub.told {
            record(TapeEvent(k: "gone", c: channel))
            killpg(process.pid, SIGKILL)
        }
    }

    /// `mark`：CuePad 给托管进程的标记（`HostMark`，每次一个新的 UUID）。一并比对，回放时录下的钩子环境里那个才换成这次的。
    private func replayProcess(_ stub: Stub, _ reader: LineReader, name: String, arguments: [String], cwd: String, mark: String?) {
        guard let channel = claim("spawn", where: { $0.d == name }, data: ([cwd] + arguments + [mark ?? ""]).joined(separator: "\u{1}"),
                                  recorded: { [$0.p ?? ""] + ($0.a ?? []) + [$0.m ?? ""] },
                                  attach: { state, channel in
                                      state.stubPids[channel] = stub.pid
                                      state.stubs[channel] = stub
                                  }) else {
            stub.send("r " + Data("录像带里没有这次启动：\(name) \(arguments.joined(separator: " "))\n".utf8).base64EncodedString())
            return stub.send("x 127")
        }
        advance()
        var lines = LineSplitter()
        while let line = reader.next() {
            let (kind, value) = Self.split(line)
            switch kind {
            case "i": for line in lines.append(Data(base64Encoded: value) ?? Data()) { input("stdin", channel: channel, data: String(decoding: line, as: UTF8.self)) }
            case "e":
                if let rest = lines.flush() { input("stdin", channel: channel, data: String(decoding: rest, as: UTF8.self)) }
                input("eof", channel: channel)
            case "s": input("signal", channel: channel)
            case "f": stub.acknowledged()
            default: break
            }
        }
        stub.acknowledged(gone: true)
        if !stub.told { input("gone", channel: channel) }
    }
}
#endif
