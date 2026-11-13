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

  @Test func 只有会话文件的已结束会话_模型照文件里最后用的_清单是这台Mac上这一家的_在线报过的那份不被同一个模型的索引盖掉() async throws {
    let opus = ModelOption(key: ModelKey(provider: "anthropic", id: "opus"), name: "Opus", thinkingLevels: [.low, .high])
    let sonnet = ModelOption(key: ModelKey(provider: "anthropic", id: "sonnet"), name: "Sonnet", thinkingLevels: [.low, .high])
    try await store.recordMacAgents(host: host, name: nil, [MacAgent(kind: .pi, model: opus.key, models: [opus, sonnet])])
    func index(_ id: String, _ model: ModelKey, thinking: String? = nil) async throws {
      try await store.upsertSession(
        IndexedSession(id: id, path: "/s/\(id).jsonl", cwd: "/w", title: id, lastActivityAt: .now, model: model, thinking: thinking), host: host)
    }

    try await index("terminal", sonnet.key, thinking: "high")
    let terminal = try #require(try await states()["terminal"])
    #expect(terminal.model?.key == sonnet.key)
    #expect(terminal.thinking == .known(.high))
    #expect(try await store.catalog(of: terminal)?.models == [opus, sonnet], "没连过桥：清单是这台 Mac 上这一家的")

    try await recorder.update(sessionID: "bridged", state: .settled, title: "bridged", modelState: ModelState(model: opus, models: [opus]))
    try await recorder.end(sessionID: "bridged")
    try await index("bridged", opus.key)
    let bridged = try #require(try await states()["bridged"])
    #expect(bridged.model == opus, "同一个模型：桥报的名字与档位留着")
    #expect(try await store.catalog(of: bridged)?.models == [opus], "连过桥：清单是它自己报的")
    try await index("bridged", sonnet.key)
    #expect(try await states()["bridged"]?.model?.key == sonnet.key, "文件里换了模型：照文件")
  }
}
