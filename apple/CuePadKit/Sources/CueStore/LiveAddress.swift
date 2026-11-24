import Foundation

public enum LiveAddress {
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
      if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
        return isLocal(URL(string: "http://\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])")!)
      }
      return false
    }
    return !host.contains(".") && !host.contains(":")
  }

  public static func shown(_ url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else { return url.absoluteString }
    let port = components.port.map { ":\($0)" } ?? ""
    let path = components.path == "/" ? "" : components.path
    return host + port + path + (components.query.map { "?\($0)" } ?? "")
  }
}

#if os(macOS)
extension CueStore {
  public func liveOwner(_ sessionID: String) throws -> LiveServers.Owner {
    let process = try db.first("SELECT pid, startedAt FROM piProcesses WHERE sessionID = ?", [sessionID]) {
      SessionProcess(pid: Int32($0.int(0)), startedAt: $0.int(1))
    }
    return LiveServers.Owner(process: process, directory: try indexedSession(sessionID)?.cwd)
  }

  public func liveAgents() throws -> [String: LiveServers.Owner] {
    Dictionary(try db.query("SELECT sessionID, pid, startedAt FROM piProcesses") { row in
      (row.text(0), LiveServers.Owner(process: SessionProcess(pid: Int32(row.int(1)), startedAt: row.int(2)), directory: nil))
    }, uniquingKeysWith: { first, _ in first })
  }

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
