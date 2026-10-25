#if os(macOS)
import CueStore
import Foundation
import Testing

/// 真实两进程：`cuepad` 子进程写入，本进程 Store 的观察者被跨进程通知唤醒并读到新卡。
@Suite struct CrossProcessTests {
  private static func run(_ binary: URL, _ arguments: [String], library: URL) async throws -> Int32 {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.environment = ["CUEPAD_LIBRARY_DIR": library.path]
    return try await process.runToExit()
  }

  @Test func observerSeesCardWrittenByCLIProcess() async throws {
    let sandbox = try Fixture()
    let binary = try cuepadBinary()
    let stream = sandbox.store.observe { try $0.cards(in: Project.defaultID).map(\.body) }

    let seen = try await withThrowingTaskGroup(of: [String].self) { group in
      group.addTask {
        var launched = false
        for try await bodies in stream {
          if bodies.contains("来自 CLI 进程") { return bodies }
          guard !launched else { continue }
          launched = true  // 收到订阅后的初始值，观察者已就位，再让子进程写
          let status = try await Self.run(binary, ["card", "add", "--body", "来自 CLI 进程"], library: sandbox.directory)
          #expect(status == 0)
        }
        return []
      }
      group.addTask {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
      }
      defer { group.cancelAll() }
      return try await group.next() ?? []
    }
    #expect(seen == ["来自 CLI 进程"])
  }
}
#endif
