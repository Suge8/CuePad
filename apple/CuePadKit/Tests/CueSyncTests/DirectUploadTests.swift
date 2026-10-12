import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 手机写出的投送请求立即直接上传（不经引擎队列）：服务器收下后本机不再把它当待推送，撤回的删除同样直传，离线时仍待推送。
@Suite struct DirectUploadTests {
  let phone = try! Rig()
  private let target = SendTarget(kind: .piSession, name: "video", ref: "s1")

  /// 记下收到的保存与删除；`offline` 时整个请求失败。
  actor Server: RecordUploader {
    private(set) var saved: [String] = []
    private(set) var deleted: [String] = []
    var offline = false
    var rejection: CKError?

    func goOffline() { offline = true }
    func reject(with error: CKError) { rejection = error }

    func upload(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> SentRecords {
      if offline { throw CKError(.networkUnavailable) }
      if let rejection { return SentRecords(failedSaves: records.map { ($0, rejection) }, failedDeletes: ids.map { ($0, rejection) }) }
      saved += records.map(\.recordID.recordName)
      deleted += ids.map(\.recordName)
      return SentRecords(saved: records, deleted: ids)
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

    let received = try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server)

    #expect(!received)
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
}
