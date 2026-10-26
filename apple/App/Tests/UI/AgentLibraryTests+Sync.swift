#if os(macOS)
import CloudKit
import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

extension AgentLibraryTests {
    /// 两台设备经同一个云替身：Mac 写下的快照同步到手机；手机上改说明、整理从手机的工作区发出，经云到 Mac 照做，结果回到手机。
    @Test func 手机经云看到Mac的快照_发往Mac改说明与整理_结果回到手机() async throws {
        let cloud = SimulatedCloud([Self.floor(CueStore.peerFloor)])
        let macApp = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let phone = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, host: "mac-phone")
        let folder = macApp.directory.appending(path: "work/site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macApp.directory.appending(path: "claude"), withIntermediateDirectories: true)
        let project = try await macApp.services.store.createProject(name: "Site", color: "#000000")
        try await macApp.services.store.setDirectory(folder.path, for: project.id)
        try write("# Site\n", folder.appending(path: "AGENTS.md"))
        try write("# 旧的 Claude 说明\n", folder.appending(path: "CLAUDE.md"))
        for side in [macApp, phone] { side.services.startSync() }
        defer { for side in [macApp, phone] { side.services.cancelBackgroundWork() } }
        let keeping = Task { try? await macApp.services.library.keep() }
        defer { keeping.cancel() }
        try await macApp.services.executor.start()
        let workspace = Workspace(services: phone.services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }
        // 没有门铃：两边按节奏拉取的那一下由这里来
        let pulling = Task {
            while !Task.isCancelled {
                await macApp.services.syncNow()
                await phone.services.syncNow()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { pulling.cancel() }

        try await eventually("手机读到 Mac 的快照") { workspace.library?.hostID == TestApp.hostID && workspace.library?.tidies.count == 1 }
        let library = try #require(workspace.library)
        let seen = try #require(library.instruction(.project(project.id)))
        #expect(seen.text == "# Site\n")

        try write("# Site\n\nMac 上改的\n", folder.appending(path: "AGENTS.md"))
        await #expect(throws: AgentLibraryError.changedOnMac) {
            try await workspace.saveInstruction(InstructionEdit(instruction: seen.kind, base: seen.base, text: "手机改的\n"), in: library)
        }
        try await eventually("手机跟上 Mac 上的改动") { workspace.library?.instruction(.project(project.id))?.text == "# Site\n\nMac 上改的\n" }
        let current = try #require(workspace.library?.instruction(.project(project.id)))
        try await workspace.saveInstruction(InstructionEdit(instruction: current.kind, base: current.base, text: "手机改的\n"), in: library)
        #expect(read(folder.appending(path: "AGENTS.md")) == "手机改的\n")

        await workspace.tidy(library.automaticOrders, in: library)
        #expect(workspace.notice?.text.visible == "整理好了 1 件，合成稿在这里，删掉重复的")
        #expect(workspace.openLibraryItem == .instruction(.project(project.id)), "合成完直接打开合成出的那份说明")
        #expect(read(folder.appending(path: "AGENTS.md")) == "手机改的\n\n# 旧的 Claude 说明\n" && !exists(folder.appending(path: "CLAUDE.md")))
        try await eventually("手机上没有要整理的了") { workspace.library?.tidies.isEmpty == true }
    }

    private static func floor(_ version: Int) -> CKRecord {
        let record = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: CloudSync.zoneID).id)
        record[PeerFloor.field] = version as NSNumber
        return record
    }
}
#endif
