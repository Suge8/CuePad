import CueStore
import Foundation
import Testing

/// 另一个进程提交写事务后，本进程的观察者要被唤醒（真子进程的那条在 CueCLITests）。这里守经符号链接打开同一个库：
/// 用同一个库文件上的第二个 `CueStore` 实例代表另一个进程，它有独立的连接，提交对本实例而言就是外部变更。
@Suite struct CrossProcessTests {
  let fixture = try! Fixture()

  @Test(.timeLimit(.minutes(1)))
  func libraryReachedThroughASymlinkedPathStillShares() async throws {
    let link = FileManager.default.temporaryDirectory.appending(path: "cuepad-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
    defer { try? FileManager.default.removeItem(at: link) }
    let viaLink = try CueStore(location: .isolated(link))
    var values = fixture.store.observe { try $0.cards(in: nil).count }.makeAsyncIterator()
    #expect(try await values.next() == 0)

    _ = try await viaLink.createCard(in: nil, body: "x")

    #expect(try await values.next() == 1)
  }
}
