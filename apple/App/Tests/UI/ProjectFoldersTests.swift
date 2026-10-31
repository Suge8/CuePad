import CueStore
import Foundation
import Testing
@testable import CuePad

/// 项目与文件夹（iOS 与 Mac 共用的规则）：新会话列哪些去处、各由哪台 Mac 开。
struct ProjectFoldersTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func project(_ name: String) async throws -> Project { try await store.createProject(name: name, color: "#111111") }

    private func binding(_ project: Project, host: String, name: String, folder: String) -> DirectoryBinding {
        DirectoryBinding(id: UUID(), projectID: project.id, hostID: host, folder: folder, macName: name, createdAt: .now, modifiedAt: .now)
    }

    #if os(iOS)
    @Test func 同名Mac的文件夹仍按设备分别列出() async throws {
        let project = try await project("圆桌")
        for host in ["mac-a", "mac-b"] {
            try await store.recordMacAgents(host: host, name: "同名 Mac", [])
            try await PiStateRecorder(store: store, hostID: host).update(
                sessionID: host, state: .settled, title: host, directory: "/work/\(host)")
        }
        let workspace = Workspace(services: app.services)
        workspace.folderPicker = project
        let candidates = ProjectFolders.candidates(
            folders: try await store.sessionFolders(), bindings: try await store.directoryBindings(),
            projects: try await store.projects(), excluding: workspace.folderPicker?.id)
        let groups = ProjectFolders.candidateGroups(candidates)
        #expect(groups.map(\.id) == ["mac-a", "mac-b"])
        #expect(groups.map(\.name) == ["同名 Mac", "同名 Mac"])
        #expect(groups.flatMap(\.items).map(\.folder) == ["mac-a", "mac-b"])
        #expect(Set(groups.map(\.id)).count == groups.count)
    }
    #endif

    /// 手机上（不认哪台是本机）：按项目顺序，没绑文件夹的交给干活的 Mac，绑在几台 Mac 上的每台一项，只有这种才写 Mac 名；
    /// Mac 上只认本机的绑定，只绑在别的 Mac 上的项目在本机建工作区。
    @Test func 新会话只列项目_手机上每台绑定的Mac一项_Mac上只认本机() async throws {
        let a = try await project("A"), b = try await project("B"), c = try await project("C")
        let bindings = [
            binding(a, host: "mac-a", name: "Studio", folder: "app"), binding(a, host: "mac-b", name: "Air", folder: "app"),
            binding(b, host: "mac-b", name: "Air", folder: "site"),
        ]

        let phone = ProjectFolders.launchPlaces(projects: [a, b, c], bindings: bindings, host: nil, workMac: "mac-a")
        #expect(phone.map(\.project.name) == ["A", "A", "B", "C"])
        #expect(phone.map(\.host) == ["mac-a", "mac-b", "mac-b", "mac-a"])
        #expect(phone.map(\.detail) == ["Studio", "Air", nil, nil])
        #expect(Set(phone.map(\.id)).count == phone.count)

        let mac = ProjectFolders.launchPlaces(projects: [a, b], bindings: bindings, host: "mac-a", workMac: "mac-b")
        #expect(mac.map(\.project.name) == ["A", "B"])
        #expect(mac.map(\.host) == ["mac-a", "mac-a"])
        #expect(mac.map(\.detail) == [nil, nil])
    }
}
