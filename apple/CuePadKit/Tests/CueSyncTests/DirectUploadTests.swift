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

    func goOffline() { offline = true }

    func upload(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> SentRecords {
      if offline { throw CKError(.networkUnavailable) }
      saved += records.map(\.recordID.recordName)
      deleted += ids.map(\.recordName)
      return SentRecords(saved: records, deleted: ids)
    }
  }

  @Test func aRequestUploadedDirectlyIsNoLongerPending() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")

    try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server)

    #expect(await server.saved == [phone.id(made.id)])
    #expect(try await phone.reconcileDelta().saves.isEmpty)
  }

  @Test func aWithdrawnRequestIsDeletedOnTheServerDirectly() async throws {
    let server = Server()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")
    try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server)
    #expect(try await phone.store.withdrawDelivery(made.id))

    try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: true, via: server)

    #expect(await server.deleted == [phone.id(made.id)])
    #expect(try await phone.reconcileDelta().deletes.isEmpty)
  }

  @Test func whenOfflineTheRequestStaysPendingForTheEngineToRetry() async throws {
    let server = Server()
    await server.goOffline()
    let made = try await phone.store.requestDelivery("继续", to: target, on: "mac")

    await #expect(throws: CKError.self) {
      try await phone.coordinator.sendNow(phone.recordID(made.id), deleted: false, via: server)
    }

    #expect(try await phone.reconcileDelta().saves == [phone.id(made.id)])
  }
}
