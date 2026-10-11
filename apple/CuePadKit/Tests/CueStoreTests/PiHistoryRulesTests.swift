import CueStore
import CueTestSupport
import Foundation
import Synchronization
import Testing

/// 什么算历史（会话记录的去留）：说过话的进程退出——托管的歇着、其余进历史；没留下会话文件的删除；启动对账也按这条规则。
@Suite struct PiHistoryRulesTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  let host = "mac-a"
  var recorder: PiStateRecorder { PiStateRecorder(store: store, hostID: host) }

  private func states() async throws -> [String: PiSessionState] {
    Dictionary(uniqueKeysWithValues: try await store.piSessionPage(PiSessionQuery(limit: .max)).items.map { ($0.state.sessionID, $0.state) })
  }

  private func sessionFile() throws -> URL {
    let file = FileManager.default.temporaryDirectory.appending(path: "hist-\(UUID().uuidString).jsonl")
    try Data().write(to: file)
    return file
  }

  @Test func 进程退出按有没有会话文件与是不是托管的分三种() async throws {
    let recorder = recorder
    for id in ["silent", "terminal", "hosted"] {
      try await recorder.update(sessionID: id, state: .thinking, title: id, hosted: id == "hosted")
    }
    try await recorder.exited(sessionID: "silent", file: URL(filePath: "/no/such/file.jsonl"), hosted: false)
    try await recorder.exited(sessionID: "terminal", file: try sessionFile(), hosted: false)
    try await recorder.exited(sessionID: "hosted", file: try sessionFile(), hosted: true)

    let all = try await states()
    #expect(all["silent"] == nil, "没说过话：记录删掉")
    #expect(all["terminal"]?.state == .known(.ended), "终端里的 Pi 退出：进历史")
    #expect(all["hosted"]?.state == .known(.settled) && all["hosted"]?.hosted == true, "托管的：歇着，记录留着")
    #expect(try await store.piSessionPage(.current).items.map(\.state.sessionID) == ["hosted"], "只有歇着的托管会话在现在")

    // 用户结束它才进历史
    try await recorder.end(sessionID: "hosted")
    #expect(try await states()["hosted"]?.state == .known(.ended))
  }

  /// 歇下是一次提交过的写入：订阅它的界面、跨进程通知与同步都收到。
  @Test func 托管会话歇下时订阅收到变更() async throws {
    let recorder = recorder
    try await recorder.update(sessionID: "hosted", state: .thinking, title: "hosted", hosted: true)
    let seen = Mutex<[Open<PiWorkState>]>([])
    let watcher = Task { [store] in
      for try await states in store.observe({ try $0.piSessionPage(.current).items.map(\.state.state) }) { seen.withLock { $0 += states } }
    }
    defer { watcher.cancel() }
    try await Task.sleep(for: .milliseconds(200))

    try await recorder.exited(sessionID: "hosted", file: try sessionFile(), hosted: true)

    for _ in 0..<300 where seen.withLock({ $0.last }) != .known(.settled) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(seen.withLock { $0.last } == .known(.settled), "订阅收到歇着")
  }

  @Test func 启动对账_托管的歇着_其余记为已结束_没有会话文件的清掉_在线的不动() async throws {
    let recorder = recorder
    for id in ["terminal", "hosted", "hosted-silent", "old-ended", "live-new"] {
      try await recorder.update(sessionID: id, state: .thinking, title: id, hosted: id.hasPrefix("hosted") || id == "live-new")
    }
    try await recorder.end(sessionID: "old-ended")
    // 有会话文件的有索引（本机会话文件索引）；"hosted-silent" 与 "old-ended" 没有
    for id in ["terminal", "hosted"] {
      try await store.upsertPiSession(PiSession(id: id, path: "/s/\(id).jsonl", cwd: "/w", title: id, lastActivityAt: .now), host: host)
    }

    try await recorder.reset()
    #expect(try await states()["terminal"]?.state == .known(.ended))
    #expect(try await states()["hosted"]?.state == .known(.settled))

    // 对账之后才连上桥的新会话（还没有会话文件）：记录器正在跟它，对账不删
    try await recorder.update(sessionID: "live-new", state: .settled, title: "live-new", hosted: true)
    try await store.retainPiSessions(paths: ["/s/terminal.jsonl", "/s/hosted.jsonl"], host: host)
    try await recorder.dropUnindexedHosted()
    #expect(Set(try await states().keys) == ["terminal", "hosted", "live-new"], "没有会话文件的已结束与歇着的托管记录被清掉，有的与在线的留着")
  }
}
