#if os(macOS)
import Darwin
import Foundation

extension LiveServers {
  /// 一个在监听的 TCP 口：绑的地址（nil 是通配）与它接哪几族（v6 的通配不设 V6ONLY 时两族都接）。
  struct Socket {
    let pid: pid_t
    let port: Int
    let v4: Bool
    let v6: Bool
    let address: Address?
  }

  enum Address: Hashable {
    case v4(in_addr_t)
    case v6([UInt8])

    static let loopback4 = Address.v4(in_addr_t(0x7f00_0001).bigEndian)
    static let loopback6 = Address.v6(Array(repeating: 0, count: 15) + [1])

    var isLoopback: Bool {
      switch self {
      case .v4(let raw): UInt32(bigEndian: raw) >> 24 == 127
      case .v6: self == Self.loopback6
      }
    }

    var host: String {
      switch self {
      case .v4(var raw): text(AF_INET, &raw, INET_ADDRSTRLEN)
      case .v6(var bytes): "[\(text(AF_INET6, &bytes, INET6_ADDRSTRLEN))]"
      }
    }

    private func text(_ family: Int32, _ address: UnsafeRawPointer, _ size: Int32) -> String {
      var buffer = [CChar](repeating: 0, count: Int(size))
      _ = inet_ntop(family, address, &buffer, socklen_t(size))
      return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }

  /// 问哪个地址到得了这个口：连一个本机地址时，绑了这个具体地址的口先接，没有才轮到通配的。
  /// 问 localhost 时 127.0.0.1 与 ::1 都可能连上，只有两处都没有别人接时才问它；否则改问这个口自己接得到的那一个回环地址，都被别人接走就不认。
  /// 绑在局域网地址上的照问那个地址。
  static func reach(_ socket: Socket, among all: [Socket]) -> URL? {
    func url(_ host: String) -> URL? { URL(string: "http://\(host):\(socket.port)") }
    if let address = socket.address, !address.isLoopback { return url(address.host) }
    func answering(_ address: Address) -> Set<pid_t> {
      let here = all.filter { $0.port == socket.port }
      let exact = here.filter { $0.address == address }
      let wide = here.filter { $0.address == nil && (address == .loopback4 ? $0.v4 : $0.v6) }
      return Set((exact.isEmpty ? wide : exact).map(\.pid))
    }
    var own: [Address] = []
    if let address = socket.address { own = [address] } else {
      if socket.v4 { own.append(.loopback4) }
      if socket.v6 { own.append(.loopback6) }
    }
    let mine = own.filter { answering($0).contains(socket.pid) }
    guard let first = mine.first else { return nil }
    let shared = [Address.loopback4, .loopback6].allSatisfy { answering($0).subtracting([socket.pid]).isEmpty }
    return url(shared ? "localhost" : first.host)
  }
}
#endif
