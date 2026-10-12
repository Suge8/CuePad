import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 手机写出的投送请求立即直接上传（不经引擎队列）：服务器收下后本机不再把它当待推送，撤回的删除同样直传，离线时仍待推送。
@Suite struct DirectUploadTests {
  let phone = try! Rig()
  let mac = try! Rig()
  private let target = SendTarget(kind: .piSession, name: "video", ref: "s1")

  /// 带版本标签的服务器替身：和真的一样，保存要带着服务器上当前的标签（`.ifServerRecordUnchanged`），否则以 `serverRecordChanged` 拒绝并附上服务器的版本；
  /// 收下后换一个新标签并回传。`offline` 时整个请求失败。
  actor Server: RecordUploader {
    private(set) var saved: [String] = []
    private(set) var deleted: [String] = []
    private var current: [String: CKRecord] = [:]
    private var counter = 0
    var offline = false
    var rejection: CKError?

    /// 服务器收下一条后立刻执行（模拟上传期间本机又改了这条记录）。
    var afterAccepting: (@Sendable () throws -> Void)?

    func goOffline() { offline = true }
    func onAccept(_ action: @escaping @Sendable () throws -> Void) { afterAccepting = action }
    func reject(with error: CKError) { rejection = error }

    func record(_ name: String) -> CKRecord? { current[name] }

    /// 服务器上这条记录此刻的内容。
    func row(_ name: String) -> SyncRow? { current[name].flatMap(RecordMapper.row(from:)) }

    func upload(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> SentRecords {
      if offline { throw CKError(.networkUnavailable) }
      if let rejection { return SentRecords(failedSaves: records.map { ($0, rejection) }, failedDeletes: ids.map { ($0, rejection) }) }
      var sent = SentRecords()
      for record in records {
        let name = record.recordID.recordName
        if let server = current[name], server.recordChangeTag != record.recordChangeTag {
          sent.failedSaves.append((record, CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])))
        } else if current[name] == nil, record.recordChangeTag != nil {
          sent.failedSaves.append((record, CKError(.unknownItem)))
        } else {
          counter += 1
          let accepted = Self.accepted(record, tag: "tag-\(counter)")
          current[name] = accepted
          saved.append(name)
          sent.saved.append(accepted)
          try afterAccepting?()
        }
      }
      for id in ids {
        current[id.recordName] = nil
        deleted.append(id.recordName)
        sent.deleted.append(id)
      }
      return sent
    }

    /// 发来的记录被收下后的样子：字段不变，版本标签换新。标签是只读的，只能改归档里的系统字段再解出来。
    private static func accepted(_ sent: CKRecord, tag: String) -> CKRecord {
      let coder = NSKeyedArchiver(requiringSecureCoding: true)
      sent.encodeSystemFields(with: coder)
      coder.finishEncoding()
      let archive = try! PropertyListSerialization.propertyList(from: coder.encodedData, format: nil)
      var xml = String(decoding: try! PropertyListSerialization.data(fromPropertyList: archive, format: .xml, options: 0), as: UTF8.self)
      let count = ((archive as! [String: Any])["$objects"] as! [Any]).count
      xml = xml.replacingOccurrences(of: "\t</array>\n\t<key>$top</key>", with: "\t<string>\(tag)</string>\n\t</array>\n\t<key>$top</key>")
      let key = xml.range(of: "<key>ETag</key>")!
      let open = xml.range(of: "<integer>", range: key.upperBound..<xml.endIndex)!
      let close = xml.range(of: "</integer>", range: open.upperBound..<xml.endIndex)!
      xml.replaceSubrange(open.upperBound..<close.lowerBound, with: String(count))
      let decoder = try! NSKeyedUnarchiver(forReadingFrom: Data(xml.utf8))
      decoder.requiresSecureCoding = true
      return RecordMapper.record(from: RecordMapper.row(from: sent)!, zoneID: testZone, base: CKRecord(coder: decoder))
    }
  }

  @Test func aRequestUploadedDirectlyIsNoLongerPending() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")

    _ = try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server)

    #expect(await server.saved == [phone.id(made.id)])
    #expect(try await phone.reconcileDelta().saves.isEmpty)
  }

  @Test func aWithdrawnRequestIsDeletedOnTheServerDirectly() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")
    _ = try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server)
    #expect(try await phone.store.withdrawDelivery(made.id))

    _ = try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: true, via: server)

    #expect(await server.deleted == [phone.id(made.id)])
    #expect(try await phone.reconcileDelta().deletes.isEmpty)
  }

  @Test func whenOfflineTheRequestStaysPendingForTheEngineToRetry() async throws {
    let server = Server()
    await server.goOffline()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")

    await #expect(throws: CKError.self) {
      _ = try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server)
    }

    #expect(try await phone.reconcileDelta().saves == [phone.id(made.id)])
  }

  /// 服务器逐条拒绝（限流等瞬时失败）不是整个请求失败：不能当成传好了，要告诉调用方交回引擎重试。
  @Test func aTransientRejectionOfTheRecordIsReportedAsNotReceivedAndStaysPending() async throws {
    let server = Server()
    await server.reject(with: CKError(.requestRateLimited))
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")

    let result = try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server)

    #expect(result == .rejected)
    #expect(try await phone.reconcileDelta().saves == [phone.id(made.id)])
  }

  /// 同一条记录有两个版本在路上（引擎的上传与立即上传重叠）：先回来的结果只记账它自己那一版，新版本仍待推送。
  @Test func aResultIsBookedForTheVersionItSentWhenANewerOneIsAlsoInFlight() async throws {
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac", mode: .followUp)
    let older = try #require(await phone.coordinator.record(for: phone.recordID(made.id)))
    try await Task.sleep(for: .milliseconds(5))  // 修改时间是毫秒，两个版本要落在不同的毫秒
    #expect(try await phone.store.promoteDelivery(made.id))
    let newer = try #require(await phone.coordinator.record(for: phone.recordID(made.id)))

    await phone.coordinator.handle(.sent(saved: [older], failedSaves: [], deleted: [], failedDeletes: []))
    #expect(try await phone.reconcileDelta().saves == [phone.id(made.id)])  // 新版本没传好，不能记成已推送

    await phone.coordinator.handle(.sent(saved: [newer], failedSaves: [], deleted: [], failedDeletes: []))
    #expect(try await phone.reconcileDelta().saves.isEmpty)
  }

  /// 手机新建的请求：直接上传一次就被服务器收下。
  @Test func aNewRequestIsAcceptedOnTheFirstDirectUpload() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")

    #expect(try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server) == .received)
    #expect(await server.row(phone.id(made.id))?.fields["status"] == .text("pending"))
  }

  /// 同一条记录连着改两次、每次立即上传（Mac 领取后写回结果）：第二次带着第一次服务器给的新标签，也被收下。
  @Test func theSameRecordUploadedDirectlyTwiceInARowIsAcceptedBothTimes() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac", mode: .followUp)
    #expect(try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server) == .received)
    #expect(try await phone.store.promoteDelivery(made.id))

    #expect(try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server) == .received)
    #expect(await server.row(phone.id(made.id))?.fields["mode"] == .text("steer"))
    #expect(try await phone.reconcileDelta().saves.isEmpty)
  }

  /// 引擎抢先把上一版传上去、它的结果还没回来时，立即上传带着旧标签被拒：不能就此放弃回落引擎（多等引擎的下一轮），
  /// 要拿服务器的新标签马上重传，让这一版当场传好。
  @Test func aDirectUploadBeatenByTheEnginesOlderVersionIsRetriedAtOnceWithTheNewTag() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac", mode: .followUp)
    let id = phone.recordID(made.id)
    #expect(try await phone.coordinator.sendNow(id, deleted: false, via: server) == .received)
    #expect(try await phone.store.promoteDelivery(made.id))
    let engines = try #require(await phone.coordinator.record(for: id))  // 引擎取走的版本
    _ = try await server.upload(saving: [engines], deleting: [])  // 它先到了服务器，结果（新标签）还没回到本机
    try RawDB(phone.fixture.url).exec("UPDATE deliveryRequests SET status = 'succeeded', modifiedAt = modifiedAt + 1")

    #expect(try await phone.coordinator.sendNow(id, deleted: false, via: server) == .received)
    #expect(await server.row(phone.id(made.id))?.fields["status"] == .text("succeeded"))
    #expect(try await phone.reconcileDelta().saves.isEmpty)
  }

  /// 引擎那一版的结果比立即上传的晚回来：旧版的结果不能把版本标签与推送时间退回去，否则这条记录又成了待推送、下一次带旧标签再被拒。
  @Test func anOlderVersionsLateResultDoesNotWindBackTheBookkeeping() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac", mode: .followUp)
    let id = phone.recordID(made.id)
    #expect(try await phone.coordinator.sendNow(id, deleted: false, via: server) == .received)
    #expect(try await phone.store.promoteDelivery(made.id))
    let engines = try #require(await phone.coordinator.record(for: id))
    let engineResult = try await server.upload(saving: [engines], deleting: [])
    try RawDB(phone.fixture.url).exec("UPDATE deliveryRequests SET status = 'succeeded', modifiedAt = modifiedAt + 1")
    #expect(try await phone.coordinator.sendNow(id, deleted: false, via: server) == .received)

    await phone.coordinator.handle(.sent(saved: engineResult.saved, failedSaves: [], deleted: [], failedDeletes: []))

    #expect(try await phone.reconcileDelta().saves.isEmpty)
  }

  /// 手机的请求经服务器到 Mac，Mac 领取、写回结果后立即上传：带着拉到的版本标签，被服务器收下，手机下一次拉到的就是结果。
  @Test(.timeLimit(.minutes(1)))
  func theResultWrittenBackOnTheMacIsAcceptedOnItsDirectUpload() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")
    #expect(try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server) == .received)
    await mac.coordinator.handle(.fetched(modifications: [try #require(await server.record(phone.id(made.id)))], deletions: []))
    let (uploads, uploaded) = AsyncStream.makeStream(of: Bool.self)
    let mac = mac
    let executor = DeliveryExecutor(store: mac.store, hostID: "mac", onIssue: { Issue.record("\($0)") }, onFinished: { id in
      uploaded.yield((try? await mac.coordinator.sendNow(mac.recordID(id), deleted: false, via: server)) == .received)
    }) { _ in .succeeded }
    try await executor.start()

    var results = uploads.makeAsyncIterator()
    #expect(await results.next() == true)
    #expect(await server.row(phone.id(made.id))?.fields["status"] == .text("succeeded"))
    await executor.stop()
  }

  /// 上传期间本机又改过这条记录：这一版传好了，更新的版本要留给引擎，不能当成都传完了。
  @Test func aVersionWrittenWhileUploadingIsLeftForTheEngine() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")
    let url = phone.fixture.url
    await server.onAccept { try RawDB(url).exec("UPDATE deliveryRequests SET status = 'executing', modifiedAt = modifiedAt + 1") }

    let result = try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server)

    #expect(result == .receivedWithNewerVersionPending)
    #expect(await phone.queue.saves.contains(phone.id(made.id)))
  }

  /// 失败日志里的原因要带服务器的说明：`localizedDescription` 只有"错误 14"。
  @Test func theLoggedReasonCarriesTheServersExplanation() {
    let error = CKError(.serverRecordChanged, userInfo: ["ServerErrorDescription": "record to insert already exists"])

    #expect(error.brief.contains("14") && error.brief.contains("record to insert already exists"))
  }
}
