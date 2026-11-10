import CloudKit
import CryptoKit
import CueStore
import CueText
@testable import CueSync
import Foundation
import Testing
@testable import CuePad

/// 按流量计费的网络上手机不自动取，这里测不到（路径监视器是系统的）。
@MainActor
@Suite(.releasesLibraries)
struct FileSyncTests {
    let directory = TestLibraries.makeDirectory()

    private func attachment(_ data: Data, format: String) throws -> (record: CKRecord, key: String) {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = directory.appending(path: "upload-\(UUID().uuidString)")
        try data.write(to: file)
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let record = CKRecord(recordType: "attachments", recordID: CKRecord.ID(recordName: UUID().uuidString.lowercased(), zoneID: CloudSync.zoneID))
        for (field, value) in [("hash", hash as NSString), ("byteCount", data.count as NSNumber), ("format", format as NSString),
                               ("createdAt", now as NSNumber), ("modifiedAt", now as NSNumber)] as [(String, any CKRecordValue)] {
            record[field] = value
        }
        record[RecordMapper.fileKey] = CKAsset(fileURL: file)
        return (record, AttachmentKey.make(hash: hash, format: format))
    }

    @Test func 别的设备的文件先到记录_手机只自动取小的_大的用到时取() async throws {
        let small = pngData(width: 8, height: 8)
        let big = Data(repeating: 7, count: FileFetcher.phoneAutoLimit + 1)
        let (smallRecord, smallKey) = try attachment(small, format: "png")
        let (bigRecord, bigKey) = try attachment(big, format: "bin")
        let cloud = SimulatedCloud([.peerFloor(CueStore.peerFloor), smallRecord, bigRecord])
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = app.services!
        let files = services.store.files
        services.startSync()
        defer { services.cancelBackgroundWork() }

        try await eventually("记录到了") {
            let small = try await services.store.hasAttachment(smallKey)
            let big = try await services.store.hasAttachment(bigKey)
            return small && big
        }
        try await eventually("小文件自动取到") { files.fileURL(for: smallKey) != nil }
        #if os(macOS)
        try await eventually("Mac 大文件也自动取") { files.fileURL(for: bigKey) != nil }
        #else
        try await eventually("自动取的都结束了") { services.fileTransfers.isEmpty }
        #expect(files.fileURL(for: bigKey) == nil)
        #endif

        let url = try await services.fetchFile(bigKey)
        #expect(try Data(contentsOf: url) == big)
        #expect(try Data(contentsOf: try #require(files.fileURL(for: smallKey))) == small)
    }
}
