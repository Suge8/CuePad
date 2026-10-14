import CueStore
import Darwin
import Foundation

/// `cuepad hook <agent>`：CuePad 写进 Agent 钩子配置的命令，把这次钩子调用转给 CuePad（`AgentHookEnvelope`），回的内容原样写到标准输出。
/// 不经资料库，也不报错：CuePad 没在运行、连不上时什么都不输出，退出码 0，Agent 照常往下走。
enum HookCommand {
  static func run(agent: AgentKind, input: Data, environment: [String: String]) -> Data {
    let relayed = environment.filter { key, _ in AgentHookEnvelope.relayedPrefixes.contains { key.hasPrefix($0) } }
    let pid = environment["CLAUDE_PID"].flatMap(Int32.init) ?? getppid()
    let envelope = AgentHookEnvelope(agent: agent, input: input, environment: relayed, pid: pid, tty: controllingTerminal(of: pid))
    guard var line = try? JSONEncoder().encode(envelope), let fd = connect(AgentHookEnvelope.socketPath(environment: environment).path) else {
      return Data()
    }
    defer { close(fd) }
    line.append(0x0A)
    let written = line.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n <= 0 { return false }
        offset += n
      }
      return true
    }
    // 不半关写端：CuePad 把连接断开当作"钩子进程走了"（这次调用被 Agent 收回）
    guard written else { return Data() }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n <= 0 { break }
      reply.append(contentsOf: buffer[0..<n])
    }
    return reply
  }

  private static func connect(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { close(fd); return nil }
    return fd
  }

  /// 进程的控制终端名（如 `ttys012`）；没有终端（钩子自己就没有，后台服务也没有）为 nil。
  /// 命令行只在 Mac 上跑；Kit 在 iOS 上编译测试时没有 libproc。
  static func controllingTerminal(of pid: Int32) -> String? {
    #if os(iOS)
    return nil
    #else
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32(bitPattern: -1),
          let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
    let tty = String(cString: name)
    return tty == "??" ? nil : tty
    #endif
  }
}
