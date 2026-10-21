#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// 起进程的底层：经中转挂到 launchd 下、登记退出事件、读描述符。
extension ChildProcess {
    /// 中转脚本：后台的子 shell 自成进程组（`set -m`：作业控制下也不把标准输入换成空设备、不忽略 SIGINT 与 SIGQUIT），
    /// 等 `goFD` 读到 EOF（App 已登记它的退出事件）再 exec 成要起的命令；`reportFD` 报出它的 PID，中转随即退出，它就挂到 launchd 下。
    static let relay = #"set -m; { read -r _ <&8; exec "$@" 8<&-; } 9>&- & echo $! >&9"#
    static let goFD: Int32 = 8
    static let reportFD: Int32 = 9

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

    /// 读到 EOF，返回读到的全部。
    static func readToEnd(_ fd: Int32) async -> Data {
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
    static func lifted(_ fd: Int32) throws -> Int32 {
        defer { close(fd) }
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, reportFD + 1)
        guard moved >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EMFILE) }
        return moved
    }
}

#endif
