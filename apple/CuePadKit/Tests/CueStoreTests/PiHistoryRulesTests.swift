import CueStore
import Foundation
import Testing

/// 什么算历史（会话记录的去留）：说过话的进程退出——托管的歇着、其余进历史，手上还有活的记为被打断；没留下会话文件的删除；
/// 启动对账也按这条规则，只对进程确实没了的。
@Suite struct PiHistoryRulesTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  let host = "mac-a"
  var recorder: PiStateRecorder { PiStateRecorder(store: store, hostID: host) }

  private func states() async throws -> [String: PiSessionState] {
    Dictionary(uniqueKeysWithValues: try await store.piSessionPage(PiSessionQuery(limit: .max)).items.map { ($0.state.sessionID, $0.state) })
  }

  /// 没说过话的删掉、托管的歇着到用户结束，见 App 的 HistoryRulesTests；终端里说过话的进程退出就进历史。
  @Test func 终端里说过话的会话进程退出_进历史() async throws {
    try await recorder.update(sessionID: "terminal", state: .settled, title: "terminal")
    try await recorder.exited(sessionID: "terminal", spoke: true)
    #expect(try await states()["terminal"]?.state == .known(.ended))
    #expect(try await store.piSessionPage(.current).items.isEmpty)
  }

  /// 启动对账收尾的是记下的进程已经不在了的（这里一律判为不在）。
  @Test func 启动对账_托管的歇着_其余记为已结束_没有会话文件的清掉_在线的不动() async throws {
    let recorder = recorder
    for (index, id) in ["terminal", "hosted", "hosted-silent", "old-ended", "live-new"].enumerated() {
      try await recorder.update(
        sessionID: id, state: .settled, title: id, hosted: id.hasPrefix("hosted") || id == "live-new",
        process: PiProcess(pid: Int32(index + 1), startedAt: 1))
    }
    try await recorder.end(sessionID: "old-ended")
    // 有会话文件的有索引（本机会话文件索引）；"hosted-silent" 与 "old-ended" 没有
    for id in ["terminal", "hosted"] {
      try await store.upsertPiSession(IndexedSession(id: id, path: "/s/\(id).jsonl", cwd: "/w", title: id, lastActivityAt: .now), host: host)
    }

    try await recorder.reset { _ in false }
    #expect(try await states()["terminal"]?.state == .known(.ended))
    #expect(try await states()["hosted"]?.state == .known(.settled))

    // 对账之后才连上桥的新会话（还没有会话文件）：记录器正在跟它，对账不删
    try await recorder.update(sessionID: "live-new", state: .settled, title: "live-new", hosted: true)
    try await store.retainPiSessions(paths: ["/s/terminal.jsonl", "/s/hosted.jsonl"], agent: .pi, host: host)
    try await recorder.dropUnindexedHosted(of: .pi)
    #expect(Set(try await states().keys) == ["terminal", "hosted", "live-new"], "没有会话文件的已结束与歇着的托管记录被清掉，有的与在线的留着")
  }
}
