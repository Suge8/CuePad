import CueStore
import Foundation
import Testing

/// 另一个进程（如 `cuepad` 命令行）提交写事务后，本进程的观察者要被唤醒。
/// 这里用同一个库文件上的第二个 `CueStore` 实例代表"另一个进程"：它有独立的连接，提交对本实例而言就是外部变更。
@Suite struct CrossProcessTests {
  let fixture = try! Fixture()

  @Test(.timeLimit(.minutes(1)))
  func anotherConnectionsCommitWakesObserversOfAnyTable() async throws {
    let app = fixture.store
    let cli = try CueStore(url: fixture.url)
    // 观察的是项目表；外部变更"不猜表"，整体重读，所以卡片写入也会唤醒它
    var values = app.observe([.projects]) { try $0.cards(in: nil).map(\.body) }.makeAsyncIterator()
    #expect(try await values.next() == [])

    _ = try await cli.createCard(in: nil, body: "from the other process")

    #expect(try await values.next() == ["from the other process"])
  }

  @Test(.timeLimit(.minutes(1)))
  func ownCommitsAreNotProcessedTwice() async throws {
    let app = fixture.store
    let cli = try CueStore(url: fixture.url)
    var values = app.observe([.cards]) { try $0.cards(in: nil).count }.makeAsyncIterator()
    #expect(try await values.next() == 0)

    _ = try await app.createCard(in: nil, body: "own")
    #expect(try await values.next() == 1)
    _ = try await cli.createCard(in: nil, body: "external")
    #expect(try await values.next() == 2)
    _ = try await app.createCard(in: nil, body: "own again")
    #expect(try await values.next() == 3)  // 中间没有多出重复的通知
  }

  @Test(.timeLimit(.minutes(1)))
  func libraryReachedThroughASymlinkedPathStillShares() async throws {
    let link = FileManager.default.temporaryDirectory.appending(path: "cuepad-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
    defer { try? FileManager.default.removeItem(at: link) }
    let viaLink = try CueStore(url: link.appending(path: "cuepad.db"))
    var values = fixture.store.observe([.cards]) { try $0.cards(in: nil).count }.makeAsyncIterator()
    #expect(try await values.next() == 0)

    _ = try await viaLink.createCard(in: nil, body: "x")

    #expect(try await values.next() == 1)
  }

}
