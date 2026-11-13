import CloudKit
@testable import CueStore
import Foundation
import Testing

@testable import CueSync

/// 随机交错（不入库）：紧急写入（Cue 的记忆、Cue 的设置）与普通写入（卡片）按种子交错，普通的批在云上慢（`slow`），随机重启。
/// 承诺：在线时紧急写入的这一版（或更新的）`bound` 内被服务器收下，不等后台那一路（同一条记录只一版在路上：
/// 写时它的上一版正在后台那一批里，从那一版收下时起算）；同一版不交两次；
/// Cue 一轮里一步步更新状态、留给你回的没变时，不算马上传（只有留给你回的变了才算，别的进程改的也算）；
/// Cue 的话到时连同它此刻的状态（之前的写入留下、还没传的）一起到；
/// 离线期间写的，恢复连通后（App 收到连通就拉一次）`recover` 内补上。只有种子决定写什么、什么时候重启与断网。
@Suite(.serialized) struct UrgentInterleaveTests {
  static let seeds: [UInt64] = {
    let env = ProcessInfo.processInfo.environment
    let first = UInt64(env["FUZZ_SEED"] ?? "1")!, count = UInt64(env["FUZZ_SEEDS"] ?? "5")!
    return Array(first..<(first + count))
  }()
  static let bound = Duration.milliseconds(400)
  static let recover = Duration.seconds(2)

  @Test(arguments: seeds) func urgentWritesLeaveRightAway(seed: UInt64) async throws {
    var rng = SplitMix(seed: seed)
    let fixture = try Fixture()
    let store = fixture.store
    let cloud = UrgentCloud()
    var sync = CloudSync(store: store) { cloud }
    await sync.start()
    try await sync.syncNow()
    var lines: [UUID] = []
    var cards: [UUID] = []
    var urgent: [(name: String, modifiedAt: Int64, at: ContinuousClock.Instant)] = []
    let cueState = CueState.recordID.uuidString.lowercased()
    let changes = await store.syncChanges()
    let hurried = Task { var sets: [Set<String>] = []; for await change in changes { if let urgent = change.urgent { sets.append(urgent) } }; return sets }
    let otherProcess = try CueStore(location: .isolated(fixture.directory))
    var said = Set<String>()
    try await StateRecorder(store: store, hostID: "mac").update(sessionID: "s", state: .settled)
    let session = try #require(try await store.sessionState("s"))
    var (steps, flips) = (0, 0)

    func wrote(_ id: UUID, _ table: Table) async throws {
      let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
      #expect(row.table == table)
      urgent.append((row.id, row.modifiedAt, .now))
    }

    for _ in 0..<(12 + Int(rng.next() % 10)) {
      switch rng.next() % 10 {
      case 0, 1:
        let text = "记\(rng.next() % 1000)"
        let line = try await store.noteCueLine(text, source: .you)
        lines.append(line.id)
        try await wrote(line.id, .cueLines)
      case 2:
        if !lines.isEmpty {
          let id = lines[Int(rng.next() % UInt64(lines.count))], pinned = rng.next() % 2 == 0
          await nextMillisecond()
          try await store.pinCueLine(id, pinned)
          try await wrote(id, .cueLines)
        }
      case 3:
        let name = "Cue\(rng.next() % 100)"
        await nextMillisecond()
        _ = try await store.updateCueProfile { $0.name = name }
        try await wrote(CueProfile.recordID, .cueProfile)
      case 4, 5:
        for _ in 0..<(1 + rng.next() % 5) { cards.append(try await store.createCard(body: "c\(rng.next() % 1000)").id) }
      case 6:
        if rng.next() % 4 == 0 {
          await sync.stop()
          sync = CloudSync(store: store) { cloud }
          await sync.start()
        }
      case 8:
        for _ in 0..<(1 + rng.next() % 4) {
          await nextMillisecond()
          try await store.setCueState(.thinking, detail: "第\(rng.next() % 1000)步")
          steps += 1
        }
        if rng.next() % 3 == 0 {
          let message = try await store.addCueMessage(.cue, text: "说\(rng.next() % 1000)")
          said.insert(message.id.uuidString.lowercased())
          try await wrote(message.id, .cueMessages)
          try await wrote(CueState.recordID, .cueState)
        }
      case 9:
        let before = try await store.cueState()?.left ?? []
        await nextMillisecond()
        let elsewhere = rng.next() % 2 == 0
        try await (elsewhere ? otherProcess : store).toggleLeft(session)
        try #require(try await store.cueState()?.left != before, "seed \(seed)：留给你回的没变")
        flips += 1
        try await wrote(CueState.recordID, .cueState)
        // 别的进程改的：这期间这边不写，只能靠收到通知后比出来
        if elsewhere { try await Task.sleep(for: Self.bound + .milliseconds(100)) }
      default:
        try await Task.sleep(for: .milliseconds(rng.next() % 200))
      }
    }
    try await Task.sleep(for: Self.bound + .milliseconds(200))
    for write in urgent {
      let at = await cloud.accepted(write.name, atLeast: write.modifiedAt)
      let from = max(write.at, await cloud.lastAccepted(write.name, before: write.modifiedAt, after: write.at) ?? write.at)
      #expect(at.map { $0 - from <= Self.bound } == true, "seed \(seed)：\(write.name.prefix(8)) 的 \(write.modifiedAt) 没在 \(Self.bound) 内收下（\(at.map { "\($0 - from)" } ?? "没收下")）")
    }

    // 离线期间写的，恢复后补上
    await cloud.setOffline(true)
    var offline: [(name: String, modifiedAt: Int64)] = []
    for _ in 0..<(1 + rng.next() % 3) {
      let line = try await store.noteCueLine("离线\(rng.next() % 1000)", source: .you)
      let row = try #require(try await store.syncRow(recordName: line.id.uuidString.lowercased()))
      offline.append((row.id, row.modifiedAt))
    }
    try await Task.sleep(for: .milliseconds(300))
    await cloud.setOffline(false)
    _ = try? await sync.syncNow()
    let back = ContinuousClock.now
    try await Task.sleep(for: Self.recover)
    for write in offline {
      let at = await cloud.accepted(write.name, atLeast: write.modifiedAt)
      #expect(at.map { $0 - back <= Self.recover } == true, "seed \(seed)：离线写的 \(write.name.prefix(8)) 恢复后没补上")
    }
    hurried.cancel()
    // 跟着 Cue 的话的不算：只看没有话的那几次
    let hurriedCue = await hurried.value.filter { $0.contains(cueState) && $0.isDisjoint(with: said) }.count
    #expect(hurriedCue <= flips, "seed \(seed)：Cue 的状态 \(steps) 次经过、\(flips) 次改留给你回，却有 \(hurriedCue) 次算马上传")
    let duplicates = await cloud.duplicates
    #expect(duplicates.isEmpty, "seed \(seed)：同一版交了两次 \(duplicates)")
    await sync.stop()
  }
}

extension CueStore {
  /// 留给你回的有无翻一下：直接写，不经值班 Mac 在不在线的判断（这里没有 Mac）。
  fileprivate func toggleLeft(_ session: SessionState) throws {
    try write {
      if try cueState()?.left.isEmpty == false { try putLeft([], removing: session.sessionID) } else { try putLeft([session]) }
    }
  }
}

struct SplitMix: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// 只有卡片的批慢（`slow`）：后台那一路一直有一批在路上。
actor UrgentCloud: SyncCloud {
  static let slow = Duration.seconds(1)
  private let inner: SimulatedCloud
  private var offline = false
  private var accepts: [(name: String, modifiedAt: Int64, at: ContinuousClock.Instant)] = []

  init() {
    let floor = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: CloudSync.zoneID).id)
    floor[PeerFloor.field] = CueStore.peerFloor as NSNumber
    inner = SimulatedCloud([floor])
  }

  func setOffline(_ value: Bool) { offline = value }

  func accepted(_ name: String, atLeast modifiedAt: Int64) -> ContinuousClock.Instant? {
    accepts.filter { $0.name == name && $0.modifiedAt >= modifiedAt }.map(\.at).min()
  }

  /// 早于这一版的、在 `after` 之后才收下的（写的时候它正在路上）。
  func lastAccepted(_ name: String, before modifiedAt: Int64, after: ContinuousClock.Instant) -> ContinuousClock.Instant? {
    accepts.filter { $0.name == name && $0.modifiedAt < modifiedAt && $0.at > after }.map(\.at).max()
  }

  var duplicates: [String] {
    Dictionary(grouping: accepts, by: { "\($0.name.prefix(8))@\($0.modifiedAt)" }).filter { $0.value.count > 1 }.map(\.key)
  }

  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    if offline { throw CKError(.networkFailure) }
    if saving.contains(where: { $0.recordType == Table.cards.rawValue }) { try? await Task.sleep(for: Self.slow) }
    if offline { throw CKError(.networkFailure) }
    let sent = await inner.upload(saving: saving, deleting: deleting)
    for record in sent.saved {
      accepts.append((record.recordID.recordName, record.modifiedAt ?? 0, .now))
    }
    return sent
  }

  func accountStatus() async throws -> CKAccountStatus { await inner.accountStatus() }
  func accountName() async throws -> String { await inner.accountName() }
  func relaySecret() async throws -> Data { await inner.relaySecret() }
  func diagnosticChanges(since token: Data?) async throws -> ZoneChangeBatch { try await inner.diagnosticChanges(since: token) }
  func uploadDiagnostics(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    await inner.uploadDiagnostics(saving: saving, deleting: deleting)
  }
  func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch {
    if offline { throw CKError(.networkFailure) }
    return await inner.changes(since: token, keys: keys)
  }
  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { await inner.records(ids) }
  func uploadFile(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> SentRecords {
    try await upload(saving: [record], deleting: [])
  }
  func resumedFileUploads() async throws -> [ResumedUpload] { [] }
  func downloadFile(_ id: CKRecord.ID, progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord? {
    await inner.downloadFile(id, progress: progress)
  }
  func saveZone() async throws {}
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] { [:] }
  func save(_ subscription: CKSubscription) async throws {}
  func delete(_ id: CKSubscription.ID) async throws {}
}
