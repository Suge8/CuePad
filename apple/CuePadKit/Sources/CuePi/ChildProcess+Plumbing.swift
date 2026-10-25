#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// 起进程的底层：经中转挂到 launchd 下、登记退出事件、读描述符。
extension ChildProcess {
    /// 经中转起进程，返回它的 PID：`registered` 在它 exec 之前调（登记退出事件：已被 launchd 回收的进程登记不上，退出码就丢了）。
    /// `actions` 里放好了标准输入输出与 3 号，中转用的 `goFD`、`reportFD` 在这里放；`newSession` 时连同它在新会话里，
    /// 并留一个看守（`Placement.detached`），返回看守那根管道的写端。
    static func spawn(
        _ executable: URL, _ arguments: [String], environment: [String: String], actions: inout posix_spawn_file_actions_t?,
        newSession: Bool, registered: (pid_t) -> Void
    ) async throws -> (pid: pid_t, hold: Int32?) {
        // 起不来的（不存在、不可执行）当场抛错，不等中转里的 exec 失败
        guard access(executable.path, X_OK) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .ENOENT) }
        let reported = try pipe(), go = try pipe()
        posix_spawn_file_actions_adddup2(&actions, reported.write, reportFD)
        posix_spawn_file_actions_adddup2(&actions, go.read, goFD)
        let hold = newSession ? try pipe() : nil
        if let hold { posix_spawn_file_actions_adddup2(&actions, hold.read, holdFD) }
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 信号处置与屏蔽恢复默认：忽略的信号会跨 exec 继承（测试进程、App 都可能忽略着 SIGTERM），子进程就收不到结束信号
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        let session: Int32 = newSession ? POSIX_SPAWN_SETSID : 0
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | session))
        let argv = ([shell, "-c", relay(environment, held: hold != nil), "sh", executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var relayPID: pid_t = 0
        let code = posix_spawn(&relayPID, shell, &actions, &attributes, argv, envp)
        close(reported.write)
        close(go.read)
        if let hold { close(hold.read) }
        defer { close(go.write) }  // 放它 exec
        guard code == 0 else {
            close(reported.read)
            if let hold { close(hold.write) }
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        // 中转报完 PID 就退出（报告管道读到 EOF）；它是本进程的子进程，这里回收
        let report = await readToEnd(reported.read)
        var status: Int32 = 0
        waitpid(relayPID, &status, 0)
        guard let pid = pid_t(String(decoding: report, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            if let hold { close(hold.write) }
            throw POSIXError(.ECHILD)
        }
        registered(pid)
        return (pid, hold?.write)
    }

    private static let shell = "/bin/sh"
    private static let holdFD: Int32 = 7
    private static let goFD: Int32 = 8
    private static let reportFD: Int32 = 9

    /// 中转脚本：后台的子 shell 自成进程组（`set -m`：作业控制下也不把标准输入换成空设备、不忽略 SIGINT 与 SIGQUIT），
    /// 等 `goFD` 读到 EOF 再 exec 成要起的命令；`reportFD` 报出它的 PID，中转随即退出，它就挂到 launchd 下。
    /// shell 会给要起的命令补上 PWD 与 SHLVL（exec 时 SHLVL 去不掉）：要求的环境里没有的，经 env 去掉，环境与要求的一致。
    /// `held` 时再留一个看守（`Placement.detached`）：`holdFD` 上读到认领的一行就退出，读到 EOF 就结束它（SIGTERM，宽限后 SIGKILL）；
    /// 它已经不在（自己退了、`end()` 结束过）时 SIGTERM 失败，不再等宽限、补 SIGKILL。
    private static func relay(_ environment: [String: String], held: Bool) -> String {
        let added = ["PWD", "SHLVL"].filter { environment[$0] == nil }
        let command = added.isEmpty ? #""$@""# : "/usr/bin/env " + added.map { "-u \($0) " }.joined() + #""$@""#
        let start = "set -m; { read -r _ <&\(goFD); exec \(command) \(goFD)<&-; } \(reportFD)>&- \(holdFD)<&- & p=$!; "
        let grace = AgentTimeouts.endGrace.components.seconds
        let guardian = held
            ? "{ read -r _ <&\(holdFD) || { kill -TERM $p && { sleep \(grace); kill -KILL $p; }; }; } \(goFD)<&- \(reportFD)>&- 2>/dev/null & "
            : ""
        return start + guardian + "echo $p >&\(reportFD)"
    }

    /// 一根管道，两端都挪到 `lifted` 的号上。
    static func pipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return (try lifted(fds[0]), try lifted(fds[1]))
    }

    /// 进程退出事件（带退出码）到了就记下、唤醒等着的，自成进程组的再结束组里剩下的。
    /// 事件源在进程退出前一直握着自己，与这个对象的生死无关（脱离 App 的 Pi 也由它记下退出）。
    static func watchExit(_ pid: pid_t, group: Bool, shared: Shared) {
        let finish: @Sendable (Int32) -> Void = { status in
            if group { killpg(pid, SIGKILL) }
            let waiters = shared.state.withLock { s in
                s.status = status
                defer { s.waiters = [:] }
                return s.waiters.values
            }
            for waiter in waiters { waiter.resume(returning: true) }
        }
        let queue = kqueue()
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT | UInt32(NOTE_EXITSTATUS), data: 0,
            udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            close(queue)
            return finish(SIGKILL)  // 还没放它 exec 就没了：只能是被外面结束的
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: queue, queue: .global())
        source.setEventHandler {
            var event = kevent()
            var now = timespec()
            guard kevent(queue, nil, 0, &event, 1, &now) == 1 else { return }
            source.cancel()
            finish(Int32(truncatingIfNeeded: event.data))
        }
        source.setCancelHandler { close(queue) }
        source.resume()
    }

    private static func readToEnd(_ fd: Int32) async -> Data {
        final class Collected: Sendable { let data = Mutex(Data()) }
        let collected = Collected()
        await withCheckedContinuation { continuation in
            read(fd) { chunk in collected.data.withLock { $0.append(chunk) } } done: { continuation.resume() }
        }
        return collected.data.withLock { $0 }
    }

    /// 读到 EOF：每次读事件读出的块交给 `chunk`，结束时关描述符、调 `done`。
    static func read(_ fd: Int32, chunk: @escaping @Sendable (Data) -> Void, done: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "cuepad.child.read"))
        let buffer = ReadBuffer()
        source.setEventHandler {
            guard let data = buffer.read(from: fd) else { return source.cancel() }
            chunk(data)
        }
        source.setCancelHandler {
            close(fd)
            done()
        }
        source.resume()
    }

    static func scratchFile() throws -> Int32 {
        var template = Array((NSTemporaryDirectory() + "cuepad-child-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        return try lifted(fd)
    }

    /// 要交给子进程的描述符在本进程这端挪到 `reportFD` 之上、设 FD_CLOEXEC：
    /// 不撞子进程里要放的 0–9 号（dup2 按顺序做，来源若正是先放的目标号就被盖掉；来源与目标同号时 dup2 不清 FD_CLOEXEC，会被关掉），
    /// 也不漏进同时起的别的子进程（继承了写端，这边就永远等不到 EOF）。
    private static func lifted(_ fd: Int32) throws -> Int32 {
        defer { close(fd) }
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, reportFD + 1)
        guard moved >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EMFILE) }
        return moved
    }
}

#endif
