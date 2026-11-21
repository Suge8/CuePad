#if os(macOS)
import CoreVideo
import CueScreen
import CueTestSupport
import Foundation
import Synchronization
import Testing

@Suite struct ScreenServerTests {
  private final class Source: ScreenSource {
    let got = Mutex<[ScreenInput]>([])
    func watch(_ changed: @escaping @Sendable () -> Void) {}
    func rest() {}
    func frame() -> CVPixelBuffer? { nil }
    func send(_ input: ScreenInput) { got.withLock { $0.append(input) } }
  }

  /// 页面把一长段字（填充、粘贴）切成最多 400 个字一条送来，一条有一千多字节：整段到来源，它后面的输入照常到。
  @Test func 页面送来的一长段字整段到来源_后面的输入照常到() async throws {
    let source = Source()
    var port = UInt16.random(in: 49152...65000)
    var server = try ScreenServer(source: source, port: port, identity: "test", page: "")
    while (try? await server.start()) == nil {
      port += 1
      server = try ScreenServer(source: source, port: port, identity: "test", page: "")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let socket = URLSession(configuration: configuration).webSocketTask(with: try #require(URL(string: "ws://127.0.0.1:\(port)/screen")))
    socket.resume()
    defer { socket.cancel() }

    let text = String(repeating: "长", count: 400)
    try await socket.send(.string(#"{"t":"fill","i":12,"s":"\#(text)"}"#))
    try await socket.send(.string(#"{"t":"key","u":42,"d":true}"#))
    try await eventually("两条都到了来源") { source.got.withLock { $0.count } == 2 }
    let got = source.got.withLock { $0 }
    guard case .fill(12, let filled) = got[0], case .key(usage: 42, down: true) = got[1] else {
      Issue.record("到的不是这两条：\(got)")
      return
    }
    #expect(filled == text)
    _ = server
  }
}
#endif
