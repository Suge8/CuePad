#if os(macOS)
import Darwin
import Foundation

/// 测试起的进程里有些不随测试结束：Codex 终端界面自己拉起的常驻服务与它的 `pid-update-loop`（还会再起 git 拉插件）、
/// 脱离 App 的托管 Pi。它们的可执行文件、命令行或工作目录都在测试的临时目录里，收尾时按这个找到确切的 PID 停掉，
/// 不按进程名批量结束。只读本机进程表（libproc 与 sysctl），不起子进程：进程退出前（`atexit`）也能用。
///
/// 读一遍进程表要两三百毫秒（两千多个进程时实测，机器忙时要几秒），找到进程时还要等它们退出：测试跑着时不在主线程上调，
/// 也不在 Swift 并发的协作线程上调（只有核数那么多，几个用例同时收尾就占满，全进程的 async 都停下）——异步代码用 async 的那个。
/// 主线程或协作线程一停，同时在跑的回放与 CuePad 跟着停（回放换通道前要等主线程排着的处理跑完），别的用例的等待就此超时。
public enum TestProcesses {
  /// 同下，在自己的线程上做完再回来。
  public static func stop(under directories: [URL]) async {
    await withCheckedContinuation { done in
      Thread.detachNewThread {
        stop(under: directories)
        done.resume()
      }
    }
  }

  /// 停掉可执行文件、命令行或工作目录在 `directories` 里的进程（不含本进程）：先停 `pid-update-loop`（它守着常驻服务），
  /// 再停其余的；SIGTERM 后至多等 `grace`，还在的 SIGKILL。停完再看一遍，收掉期间新起的。几个目录一起给，只读一遍进程表。
  public static func stop(under directories: [URL], grace: Duration = .seconds(3)) {
    guard !directories.isEmpty else { return }
    for _ in 0..<2 {
      let found = processes(under: directories)
      guard !found.isEmpty else { return }
      let (loops, rest) = (found.filter { $0.arguments.contains(updaterArgument) }, found.filter { !$0.arguments.contains(updaterArgument) })
      for group in [loops, rest] where !group.isEmpty { terminate(group.map(\.pid), grace: grace) }
    }
  }

  /// Codex 常驻服务的守护进程的参数
  private static let updaterArgument = "pid-update-loop"

  /// 退出由 kqueue 的进程事件得知（先登记再发信号，不会错过）；登记不上的是已经没了。
  private static func terminate(_ pids: [pid_t], grace: Duration) {
    let queue = kqueue()
    defer { close(queue) }
    var alive = Set<pid_t>()
    for pid in pids {
      var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT, data: 0, udata: nil)
      if kevent(queue, &change, 1, nil, 0, nil) == 0 { alive.insert(pid) }
      kill(pid, SIGTERM)
    }
    let deadline = ContinuousClock.now + grace
    while !alive.isEmpty {
      let left = deadline - .now
      guard left > .zero else { break }
      var timeout = timespec(tv_sec: Int(left.components.seconds), tv_nsec: Int(left.components.attoseconds / 1_000_000_000))
      var event = kevent()
      guard kevent(queue, nil, 0, &event, 1, &timeout) == 1 else { break }
      alive.remove(pid_t(event.ident))
    }
    for pid in alive { kill(pid, SIGKILL) }
  }

  struct Found {
    let pid: pid_t
    let arguments: [String]
  }

  /// 各进程可执行文件、命令行与工作目录里含 `fragment` 的那些路径（目录已被删掉、进程还指着它时也找得到）。
  public static func referencedPaths(containing fragment: String) -> [String] {
    allPIDs().filter { $0 > 0 && $0 != getpid() }.flatMap { pid in
      (arguments(of: pid) + [workingDirectory(of: pid)].compactMap { $0 }).filter { $0.contains(fragment) }
    }
  }

  static func processes(under directories: [URL]) -> [Found] {
    // /tmp 是 /private/tmp 的链接：进程表里两种写法都有，比对去掉 /private 的那段
    let markers = directories.map { $0.standardizedFileURL.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") + "/" }
    func inside(_ path: String) -> Bool { markers.contains { (path + "/").contains($0) } }
    return allPIDs().compactMap { pid -> Found? in
      guard pid != getpid(), pid > 0 else { return nil }
      let arguments = self.arguments(of: pid)
      guard arguments.contains(where: { inside($0) }) || workingDirectory(of: pid).map(inside) == true else { return nil }
      return Found(pid: pid, arguments: arguments)
    }
  }

  private static func allPIDs() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(max(filled, 0))))
  }

  /// 可执行文件路径与命令行参数（`KERN_PROCARGS2`：参数个数、可执行文件路径、补齐的 \0、各个参数）；读不到（别人的进程）为空。
  private static func arguments(of pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
    let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    let strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
    return strings.prefix(count + 1).map { String(decoding: $0, as: UTF8.self) }
  }

  private static func workingDirectory(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }
}
#endif
