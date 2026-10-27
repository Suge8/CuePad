#if os(macOS)
import CloudKit
import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension AgentLibraryTests {
    /// 每份文件的正文各一条（`LibraryFileText`）：Mac 上改了一个技能的正文，经云到手机的只有这一条正文（快照随哈希改一次），手机读到新正文；
    /// 删掉一个技能，手机上那条正文也没了。"手机"是连同一个云替身的第二个进程（同 `+Sync`）。
    @Test func 改一个技能只传它那一条正文_删掉的技能手机上也没了() async throws {
        let cloud = SimulatedCloud([Self.floor(CueStore.peerFloor)])
        let macApp = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let phone = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, host: "mac-phone")
        let root = macApp.directory.appending(path: "agents/skills", directoryHint: .isDirectory)
        for name in ["a", "b", "c"] { try write("---\nname: \(name)\ndescription: \(name) 的说明\n---\n\n正文\n", root.appending(path: "\(name)/SKILL.md")) }
        for side in [macApp, phone] { side.services.startSync() }
        defer { for side in [macApp, phone] { side.services.cancelBackgroundWork() } }
        let keeping = Task { try? await macApp.services.library.keep() }
        defer { keeping.cancel() }
        let pulling = Task {
            while !Task.isCancelled {
                await macApp.services.syncNow()
                await phone.services.syncNow()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { pulling.cancel() }
        let store = phone.services.store
        func phoneText(_ name: String) async throws -> String? {
            guard let library = try await store.agentLibrary(host: nil) else { return nil }
            return try await text(.skill(root.appending(path: name).path), in: library, store: store)
        }

        try await eventually("手机读到三个技能的正文") {
            for name in ["a", "b", "c"] where try await phoneText(name) == nil { return false }
            return true
        }
        let sent = await cloud.saved.count

        try write("---\nname: b\ndescription: b 的说明\n---\n\n改过的正文\n", root.appending(path: "b/SKILL.md"))
        try await eventually("手机读到 b 的新正文") { try await phoneText("b") == "---\nname: b\ndescription: b 的说明\n---\n\n改过的正文\n" }
        let snapshot = AgentLibrary.recordID(host: TestApp.hostID).uuidString.lowercased()
        let bFile = LibraryFileText.recordID(host: TestApp.hostID, path: root.appending(path: "b/SKILL.md").path).uuidString.lowercased()
        #expect(Set(await cloud.saved.dropFirst(sent)) == [snapshot, bFile], "正文只传了 b 那一条，快照随哈希改一次")

        let cFile = root.appending(path: "c/SKILL.md").path
        try FileManager.default.removeItem(at: root.appending(path: "c"))
        try await eventually("手机上 c 的正文没了") {
            let skills = try await store.agentLibrary(host: nil)?.skills.count
            let texts = try await store.agentLibraryTexts(host: TestApp.hostID, paths: [cFile])
            return skills == 2 && texts.isEmpty
        }
        #expect(await cloud.deleted == [LibraryFileText.recordID(host: TestApp.hostID, path: cFile).uuidString.lowercased()])
    }

    /// 500 个技能：快照里只有元数据，单条记录远小于 iCloud 的 1MB 上限；正文在各自那一条里。
    @Test func 五百个技能的快照远小于1MB() async throws {
        let cloud = SimulatedCloud([Self.floor(CueStore.peerFloor)])
        let macApp = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let root = macApp.directory.appending(path: "agents/skills", directoryHint: .isDirectory)
        let body = String(repeating: "按这一步做：先读代码与一手资料，再动手；改完跑最窄的验证。\n", count: 40)
        for index in 0..<500 {
            let name = "skill-\(index)"
            let description = "第 \(index) 个技能：在写界面、查资料、发布新版本这类场景下按固定步骤做事，给出可验证的结果"
            try write("---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)", root.appending(path: "group-\(index % 12)/\(name)/SKILL.md"))
        }
        macApp.services.startSync()
        defer { macApp.services.cancelBackgroundWork() }
        let keeping = Task { try? await macApp.services.library.keep() }
        defer { keeping.cancel() }

        let id = CKRecord.ID(recordName: AgentLibrary.recordID(host: TestApp.hostID).uuidString.lowercased(), zoneID: CloudSync.zoneID)
        var uploaded: CKRecord?
        try await eventually("五百个技能的快照上了云") {
            uploaded = await cloud.records([id]).first
            return (uploaded?.encryptedValues["skills"] as String?)?.contains("skill-499") == true
        }
        let record = try #require(uploaded)
        try await eventually("五百条正文都上了云") { await cloud.saved.count >= 501 }
        let bytes = Self.size(of: record)
        print("500 个技能：快照记录 \(bytes) 字节（每个技能约 \(bytes / 500) 字节）；正文另 500 条，每条约 \(Data(body.utf8).count) 字节")
        #expect(bytes < 1_000_000 / 3, "快照 \(bytes) 字节")
    }

    /// 一条记录里各字段值的字节数（字符串按 UTF-8，数字按 8）。
    private static func size(of record: CKRecord) -> Int {
        func bytes(_ value: Any?) -> Int {
            switch value {
            case let text as String: Data(text.utf8).count
            case is NSNumber: 8
            default: 0
            }
        }
        return record.allKeys().map { bytes(record[$0]) }.reduce(0, +)
            + record.encryptedValues.allKeys().map { bytes(record.encryptedValues[$0]) }.reduce(0, +)
    }
}
#endif
