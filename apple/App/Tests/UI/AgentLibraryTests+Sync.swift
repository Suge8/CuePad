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
    /// 两台设备经同一个云替身：Mac 写下的快照同步到手机；手机上改规则、合并从手机的工作区发出，经云到 Mac 照做，结果回到手机。
    /// 这里的"手机"是第二个 Mac 进程：Mac 上的工作区只看本机的快照，手机那样读（`agentLibrary(host: nil)`）由测试自己读库。
    @Test func 手机经云看到Mac的快照_发往Mac改规则与合并_结果回到手机() async throws {
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
        func phoneSees(_ what: String, _ condition: @escaping @Sendable (AgentLibrary) -> Bool) async throws -> AgentLibrary {
            try #require(try await eventually(phone.services.store, { try $0.agentLibrary(host: nil) }) { $0.map(condition) ?? false })
        }
        // 没有门铃：两边按节奏拉取的那一下由这里来
        let pulling = Task {
            while !Task.isCancelled {
                await macApp.services.syncNow()
                await phone.services.syncNow()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { pulling.cancel() }

        let mac = TestApp.hostID
        let library = try await phoneSees("手机读到 Mac 的快照") { $0.hostID == mac && $0.tidies.count == 1 }
        let seen = try #require(library.instruction(.project(project.id)))
        #expect(seen.text == "# Site\n")

        try write("# Site\n\nMac 上改的\n", folder.appending(path: "AGENTS.md"))
        let file = LibraryFile.instruction(seen.kind)
        await #expect(throws: AgentLibraryError.changedOnMac) {
            try await workspace.saveFile(LibraryEdit(file: file, base: LibraryEdit.base(of: seen.text), text: "手机改的\n"), in: library)
        }
        let followed = try await phoneSees("手机跟上 Mac 上的改动") { $0.instruction(.project(project.id))?.text == "# Site\n\nMac 上改的\n" }
        let current = try #require(followed.instruction(.project(project.id)))
        try await workspace.saveFile(LibraryEdit(file: file, base: LibraryEdit.base(of: current.text), text: "手机改的\n"), in: library)
        #expect(read(folder.appending(path: "AGENTS.md")) == "手机改的\n")

        let merge = try #require(library.merge(into: .project(project.id)))
        await workspace.tidy([TidyOrder(tidy: merge.id)], in: library)
        #expect(workspace.notice?.text.visible == "合并好了" && workspace.notice?.action == nil, "手机发的合并没有撤销")
        #expect(read(folder.appending(path: "AGENTS.md")) == "手机改的\n\n# 旧的 Claude 说明\n")
        #expect(RelativeLink.points(folder.appending(path: "CLAUDE.md"), to: folder.appending(path: "AGENTS.md")))
        _ = try await phoneSees("手机上没有该整理的了") { $0.tidies.isEmpty }
    }

    private static func floor(_ version: Int) -> CKRecord {
        let record = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: CloudSync.zoneID).id)
        record[PeerFloor.field] = version as NSNumber
        return record
    }
}
#endif
