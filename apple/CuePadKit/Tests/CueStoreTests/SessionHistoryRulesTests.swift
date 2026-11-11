import CueStore
import Foundation
import Testing

@Suite struct SessionHistoryRulesTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  let host = "mac-a"
  var recorder: StateRecorder { StateRecorder(store: store, hostID: host) }

  private func states() async throws -> [String: SessionState] {
    Dictionary(uniqueKeysWithValues: try await store.sessionPage(SessionQuery(limit: .max)).items.map { ($0.state.sessionID, $0.state) })
  }

  /// 对账时进程一律判为不在。
  @Test func 启动对账_托管的歇着_其余记为已结束_没有会话文件的清掉_在线的不动() async throws {
    let recorder = recorder
    for (index, id) in ["terminal", "hosted", "hosted-silent", "old-ended", "live-new"].enumerated() {
      try await recorder.update(
        sessionID: id, state: .settled, title: id, hosted: id.hasPrefix("hosted") || id == "live-new",
        process: SessionProcess(pid: Int32(index + 1), startedAt: 1))
    }
    try await recorder.end(sessionID: "old-ended")
    for id in ["terminal", "hosted"] {
      try await store.upsertSession(IndexedSession(id: id, path: "/s/\(id).jsonl", cwd: "/w", title: id, lastActivityAt: .now), host: host)
    }

    _ = try store.launchMac(host: host) { _ in false }
    let reopened = self.recorder
    #expect(try await states()["terminal"]?.state == .known(.ended))
    #expect(try await states()["hosted"]?.state == .known(.settled))

    try await reopened.update(sessionID: "live-new", state: .settled, title: "live-new", hosted: true)
    try await store.retainSessions(paths: ["/s/terminal.jsonl", "/s/hosted.jsonl"], agent: .pi, host: host)
    try await reopened.dropUnindexedHosted(of: .pi)
    #expect(Set(try await states().keys) == ["terminal", "hosted", "live-new"], "没有会话文件的已结束与歇着的托管记录被清掉，有的与在线的留着")
  }
}
