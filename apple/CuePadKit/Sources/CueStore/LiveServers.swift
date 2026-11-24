#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// 本机正在监听、属于会话、答得出网页的开发服务（活预览自己认出的地址、会话条上哪些会话有活预览；`cuepad live` 不给地址时也用它）。
/// 属于哪个会话按这个顺序认，前两条认到就只归它：
/// 1. 进程的环境里带着会话 id（`AgentKind.sessionVariables`，Agent 给每条命令带的那个，`cuepad show` 认会话也是它）：谁起的就是谁的。
///    Agent 常用 nohup 把服务甩到后台，进程树断了、工作目录在别处都还认得；带着的是别的会话的 id（这一轮没问到的、已结束的）就谁也不归。
/// 2. 是会话 Agent 进程的后代：系统自带的可执行文件（/usr/bin/ruby）内核不给读环境，靠这条。
/// 3. 都没有的（你自己在终端里起的）看工作目录：在会话的工作目录之内，目录包着它的几个会话都算；会话目录是主目录、根目录这类过宽的不算。
///    只按目录认时，同一个项目里开着的几个会话会一起认领 Agent 甩到后台的服务（实测：三个会话都亮了预览、点进去是同一页）。
/// 归属对着本机知道的全部会话认，只要其中几个的结果用 `only` 说：只拿一个会话去认，别的会话 Agent 的后代（读不到环境的）会被它按目录认走。
/// 进程表只经 libproc 与 sysctl（同一用户的进程都读得到，别的用户的读不到也用不着），不起 lsof；一次扫多少个会话都只读一遍进程表。
public struct LiveServers: Sendable {
  public struct Owner: Equatable, Sendable {
    public var process: SessionProcess?
    public var directory: String?

    public init(process: SessionProcess?, directory: String?) {
      self.process = process
      self.directory = directory
    }
  }

  struct Listener: Hashable {
    let pid: pid_t
    let started: Int64
    let url: URL
    var asked: Asked { Asked(pid: pid, started: started, port: url.port ?? 0) }
  }

  struct Asked: Hashable {
    let pid: pid_t
    let started: Int64
    let port: Int
  }

  private var pages: [Asked: (page: Bool, web: Bool, at: ContinuousClock.Instant)] = [:]
  private static let retry = Duration.seconds(5)

  public init() {}

  public mutating func find(for owners: [String: Owner], only: Set<String>? = nil) async -> [String: [URL]] {
    let everyone = await Self.listening(for: owners)
    let listeners = only.map { only in everyone.filter { !$0.owners.isDisjoint(with: only) }.map { (listener: $0.listener, owners: $0.owners.intersection(only)) } } ?? everyone
    let now = ContinuousClock.now
    var once = Set<Asked>()
    let asking = listeners.map(\.listener).filter { listener in
      (pages[listener.asked].map { !$0.page && now - $0.at >= Self.retry } ?? true) && once.insert(listener.asked).inserted
    }
    await withTaskGroup(of: (Asked, Bool?).self) { group in
      for listener in asking { group.addTask { (listener.asked, await Self.answersPage(listener.url)) } }
      for await (asked, page) in group { pages[asked] = (page == true, page != nil || pages[asked]?.web == true, now) }
    }
    let all = Set(everyone.map(\.listener.asked))
    pages = pages.filter { all.contains($0.key) }
    var found: [String: [URL]] = [:]
    for (listener, keys) in listeners where pages[listener.asked]?.page == true {
      for key in keys where found[key]?.contains(listener.url) != true { found[key, default: []].append(listener.url) }
    }
    return found
  }

  /// 这几个会话名下、网页用得上的端口：`find` 问到过 HTTP 回应的（页面要调的只回 JSON 的接口也在里面），活预览的隧道只放行它们。
  /// 不说 HTTP 的（数据库、缓存）不在里面：网页本来也连不了它们，而手机那头把放行的口照搬到回环上，别的应用连得到（`LiveTunnel.Proxy.mirror`）。
  /// 只按 http 问：只开 https 的口不在里面，要靠页面地址放行（`Workspace.livePorts`）。刚起来的口等下一遍 `find` 问过才有。
  /// 值是连得到会话那个服务的本机地址（`reach`）：同一个端口号上 127.0.0.1 与 ::1 可以各是一个进程，只凭端口号连 localhost 会连到别人那里。
  public func ports(for owners: [String: Owner], only: Set<String>? = nil) async -> [String: [Int: String]] {
    var ports: [String: [Int: String]] = [:]
    for (listener, keys) in await Self.listening(for: owners, only: only) where pages[listener.asked]?.web == true {
      guard let port = listener.url.port, let host = listener.url.host(percentEncoded: false) else { continue }
      for key in keys where ports[key]?[port] == nil { ports[key, default: [:]][port] = host }
    }
    return ports
  }

  @concurrent static func listening(for owners: [String: Owner], only: Set<String>? = nil) async -> [(listener: Listener, owners: Set<String>)] {
    guard !owners.isEmpty, only?.isEmpty != true else { return [] }
    let me = getpid()
    let info = Dictionary(processes().compactMap { pid in bsd(pid).map { (pid, $0) } }, uniquingKeysWith: { first, _ in first })
    let listening: [Socket] = info.keys.flatMap { sockets($0) }
    let candidates = Set(listening.map(\.pid)).subtracting([me])
    var mine: [pid_t: Set<String>] = [:]
    for (pid, session) in sessions(of: candidates) { mine[pid] = owners[session] == nil ? [] : [session] }
    var children: [pid_t: [pid_t]] = [:]
    for (pid, item) in info { children[pid_t(item.pbi_ppid), default: []].append(pid) }
    var descended: [pid_t: Set<String>] = [:]
    for (key, owner) in owners {
      guard let process = owner.process, let root = info[process.pid], started(root) == process.startedAt else { continue }
      var queue = children[process.pid] ?? []
      while let pid = queue.popLast() {
        guard descended[pid]?.contains(key) != true else { continue }
        descended[pid, default: []].insert(key)
        queue += children[pid] ?? []
      }
    }
    var directories: [String: Set<String>] = [:]
    for (key, owner) in owners {
      if let directory = owner.directory.flatMap(realPath), !tooWide(directory) { directories[directory, default: []].insert(key) }
    }
    for pid in candidates where mine[pid] == nil {
      if let keys = descended[pid] {
        mine[pid] = keys
        continue
      }
      guard !directories.isEmpty, var path = workingDirectory(pid) else { continue }
      var keys = Set<String>()
      while true {
        keys.formUnion(directories[path] ?? [])
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { break }
        path = String(path[..<slash])
      }
      mine[pid] = keys
    }
    var found: [(listener: Listener, owners: Set<String>)] = []
    for socket in listening {
      guard let keys = mine[socket.pid].map({ only?.intersection($0) ?? $0 }), !keys.isEmpty, let url = reach(socket, among: listening) else { continue }
      found.append((Listener(pid: socket.pid, started: started(info[socket.pid]!), url: url), keys))
    }
    return found.sorted { ($0.listener.started, -($0.listener.url.port ?? 0)) > ($1.listener.started, -($1.listener.url.port ?? 0)) }
  }

  /// 这几个进程起来时的环境里带着的会话 id（`AgentKind.sessionVariables` 里第一个有值的，同 `cuepad show`）；没带、读不到的不在里面。
  /// 内核只给读同一用户、不是系统自带可执行文件的进程（实测 node、bun、python 读得到，/usr/bin/ruby、/bin/sleep 读不到）。
  static func sessions(of pids: Set<pid_t>) -> [pid_t: String] {
    var limit = 0, limitSize = MemoryLayout<Int>.size
    guard sysctlbyname("kern.argmax", &limit, &limitSize, nil, 0) == 0, limit > 0 else { return [:] }
    var buffer = [UInt8](repeating: 0, count: limit)
    let wanted = AgentKind.sessionVariables.map { Array("\($0)=".utf8) }
    var sessions: [pid_t: String] = [:]
    for pid in pids {
      var mib = [CTL_KERN, KERN_PROCARGS2, pid]
      var size = limit
      guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { continue }
      // 排法：参数个数，可执行文件路径，补的零，那几个参数，然后是环境；每段以零结尾
      var skip = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
      var at = MemoryLayout<Int32>.size
      while at < size, buffer[at] != 0 { at += 1 }
      while at < size, buffer[at] == 0 { at += 1 }
      var values = [String?](repeating: nil, count: wanted.count)
      while at < size {
        let end = buffer[at..<size].firstIndex(of: 0) ?? size
        if skip > 0 { skip -= 1 } else if end == at { break } else {
          for (index, name) in wanted.enumerated() where end - at > name.count && buffer[at..<at + name.count].elementsEqual(name) {
            values[index] = String(decoding: buffer[(at + name.count)..<end], as: UTF8.self)
          }
        }
        at = end + 1
      }
      if let session = values.lazy.compactMap(\.self).first { sessions[pid] = session }
    }
    return sessions
  }

  @concurrent static func answersPage(_ url: URL) async -> Bool? {
    var request = URLRequest(url: url)
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    let redirects = Redirects()
    guard let (bytes, response) = try? await probe.bytes(for: request, delegate: redirects) else { return redirects.seen.withLock { $0 } ? false : nil }
    bytes.task.cancel()
    return response.mimeType == "text/html"
  }

  private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
    let seen = Mutex(false)

    // 不写成 async 的那一版：Swift 6.4 给它生成 ObjC 入口时编译器崩
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
      seen.withLock { $0 = true }
      completionHandler(request)
    }
  }

  private static let probe: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 1
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()

  static func tooWide(_ directory: String) -> Bool {
    let home = realPath(UserHome.directory.path) ?? UserHome.directory.path
    return directory == "/" || home == directory || home.hasPrefix(directory + "/")
  }

  /// 内核报的工作目录是解开链接的（/private/tmp）：会话目录也解开再比。`URL.resolvingSymlinksInPath` 会反过来剥掉 /private，不用它。
  static func realPath(_ path: String) -> String? {
    guard !path.isEmpty, let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func processes() -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 8192)
    let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    return buffer.prefix(Int(max(0, bytes)) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
  }

  private static func bsd(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
  }

  private static func started(_ info: proc_bsdinfo) -> Int64 { Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec) }

  private static func workingDirectory(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }

  static func descends(_ pid: pid_t, from ancestor: SessionProcess) -> Bool {
    guard ancestor.isRunning else { return false }
    var current = pid
    while current > 1, let info = bsd(current) {
      let parent = pid_t(info.pbi_ppid)
      if parent == ancestor.pid { return true }
      current = parent
    }
    return false
  }

  private static func sockets(_ pid: pid_t) -> [Socket] {
    fds(pid).compactMap { fd in
      guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size, info.psi.soi_kind == SOCKINFO_TCP else { return nil }
      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
      let socket = tcp.tcpsi_ini
      let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_lport)))
      let v4 = socket.insi_vflag & UInt8(INI_IPV4) != 0, v6 = socket.insi_vflag & UInt8(INI_IPV6) != 0
      var local = socket.insi_laddr
      let address: Address?
      if v6 {
        let bytes = withUnsafeBytes(of: &local.ina_6) { Array($0) }
        address = bytes.allSatisfy { $0 == 0 } ? nil : .v6(bytes)
      } else {
        let raw = local.ina_46.i46a_addr4.s_addr
        address = raw == INADDR_ANY ? nil : .v4(raw)
      }
      return Socket(pid: pid, port: port, v4: v4, v6: v6, address: address)
    }
  }

  private static func fds(_ pid: pid_t) -> ArraySlice<proc_fdinfo> {
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard needed > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.size + 16)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
    return fds.prefix(Int(max(0, got)) / MemoryLayout<proc_fdinfo>.size)
  }
}
#endif
