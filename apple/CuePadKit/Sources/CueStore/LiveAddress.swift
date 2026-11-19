import Foundation

/// 一个会话请用户看的本机网页（`cuepad live`）：只记在本机表 `liveAddresses`，不同步——地址是这台 Mac 上的服务。每个会话留最后一条。
public struct LiveAddress: Equatable, Sendable {
  public var sessionID: String
  public var url: URL
  /// 由 `LiveServers` 认出的（Agent 没给地址）：服务换了端口跟过去；Agent 明说的不跟。
  public var found: Bool
  public var sentAt: Date

  public init(sessionID: String, url: URL, found: Bool, sentAt: Date) {
    self.sessionID = sessionID
    self.url = url
    self.found = found
    self.sentAt = sentAt
  }

  /// 输入的地址：只写端口（5173）当作本机；不写协议时本机、局域网与不带点的主机名用 http，其余用 https。
  public static func url(from text: String) -> URL? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(text) { return (1...65_535).contains(port) ? URL(string: "http://localhost:\(port)") : nil }
    let full: String
    if text.contains("://") {
      full = text
    } else {
      let host = text.prefix { !":/?#".contains($0) }
      let local = !host.contains(".") || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." }
      full = (local ? "http://" : "https://") + text
    }
    guard let url = URL(string: full), url.host?.isEmpty == false, ["http", "https"].contains(url.scheme?.lowercased()),
      url.port.map({ (1...65_535).contains($0) }) ?? true
    else { return nil }
    return url
  }

  /// 本机地址（Agent 能开、能操作的只有这些，`cuepad live` 与它的动词）：回环、`localhost` 与 `*.localhost`、`.local`、局域网与链路本地的 IP、
  /// 不带点的主机名（同 `url(from:)` 当作本机的那几种）。公网 IP 与带点的域名都不算。
  public static func isLocal(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased()), var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
    if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
    var v4 = in_addr(), v6 = in6_addr()
    if inet_pton(AF_INET, host, &v4) == 1 {
      let a = UInt32(bigEndian: v4.s_addr)
      let (first, second) = (a >> 24, (a >> 16) & 0xff)
      return first == 127 || first == 10 || first == 0 && a == 0 || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168)
        || (first == 169 && second == 254)
    }
    if inet_pton(AF_INET6, host, &v6) == 1 {
      let bytes = withUnsafeBytes(of: &v6) { Array($0) }
      if bytes == Array(repeating: 0, count: 15) + [1] { return true }
      if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
      if bytes[0] & 0xfe == 0xfc { return true }
      // ::ffff:a.b.c.d
      if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
        return isLocal(URL(string: "http://\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])")!)
      }
      return false
    }
    return !host.contains(".") && !host.contains(":")
  }

  /// 给人看的：不写 http://、https://，路径只有 "/" 时也不写。
  public static func shown(_ url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else { return url.absoluteString }
    let port = components.port.map { ":\($0)" } ?? ""
    let path = components.path == "/" ? "" : components.path
    return host + port + path + (components.query.map { "?\($0)" } ?? "")
  }
}

#if os(macOS)
extension CueStore {
  /// 本机有没有开着这份资料库的 CuePad.app（`cuepad live` 交接前问）：看进程开着的文件，调试实例与正式版各开各的库，不会认错。
  /// 不用在线记录（`MacPresence`）：App 崩溃后它要到期限（10 分钟）才过期，这期间会说成开着。
  public nonisolated var appIsOpen: Bool { LiveServers.appHolding(databasePath) }

  /// 记下一条，顺手清掉一天前的（过了这么久的地址多半已经不在了）。
  public func sendLive(_ url: URL, to sessionID: String, found: Bool) throws {
    try write {
      let now = Date.stamp
      try db.run("DELETE FROM liveAddresses WHERE sentAt < ?", [now.addingTimeInterval(-86_400)])
      try db.run("INSERT OR REPLACE INTO liveAddresses (sessionID, url, found, sentAt) VALUES (?, ?, ?, ?)", [sessionID, url.absoluteString, found ? 1 : 0, now])
    }
  }

  public func liveAddresses() throws -> [LiveAddress] {
    try db.query("SELECT sessionID, url, found, sentAt FROM liveAddresses ORDER BY sessionID") { row in
      URL(string: row.text(1)).map { LiveAddress(sessionID: row.text(0), url: $0, found: row.int(2) == 1, sentAt: row.date(3)) }
    }.compactMap(\.self)
  }

  /// 认会话的服务要的：承载它的进程（本机表 `piProcesses`）与它的工作目录（会话索引）。
  public func liveOwner(_ sessionID: String) throws -> LiveServers.Owner {
    let process = try db.first("SELECT pid, startedAt FROM piProcesses WHERE sessionID = ?", [sessionID]) {
      SessionProcess(pid: Int32($0.int(0)), startedAt: $0.int(1))
    }
    return LiveServers.Owner(process: process, directory: try indexedSession(sessionID)?.cwd)
  }

  /// 这几台（本机）上没结束的会话，各自的进程与工作目录，键是会话 id：已结束的不认服务。
  public func liveOwners(hosts: [String]) throws -> [String: LiveServers.Owner] {
    guard !hosts.isEmpty else { return [:] }
    let marks = Array(repeating: "?", count: hosts.count).joined(separator: ", ")
    let rows = try db.query(
      """
      SELECT s.sessionID, p.pid, p.startedAt, i.cwd FROM piSessionStates s
      LEFT JOIN piProcesses p ON p.sessionID = s.sessionID LEFT JOIN piSessions i ON i.id = s.sessionID
      WHERE s.hostID IN (\(marks)) AND \(WorkState.outsideSQL(WorkState.closed, column: "s.state"))
      """, hosts
    ) { row in
      (row.text(0), LiveServers.Owner(
        process: row.intOrNil(1).map { SessionProcess(pid: Int32($0), startedAt: row.int(2)) }, directory: row.textOrNil(3)))
    }
    return Dictionary(rows, uniquingKeysWith: { first, _ in first })
  }
}
#endif
