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

    // MARK: 新会话只列项目

    @Test func 新会话只列项目_按项目顺序_没绑文件夹的交给干活的Mac_绑在几台Mac上的每台一项() async throws {
        let a = try await project("A"), b = try await project("B"), c = try await project("C")
        let bindings = [
            binding(a, host: "mac-a", name: "Studio", folder: "app"), binding(a, host: "mac-b", name: "Air", folder: "app"),
            binding(b, host: "mac-a", name: "Studio", folder: "site"),
        ]

        let places = ProjectFolders.launchPlaces(projects: [a, b, c], bindings: bindings, host: nil, workMac: "mac-b")

        #expect(places.map(\.project.name) == ["A", "A", "B", "C"])
        #expect(places.map(\.host) == ["mac-a", "mac-b", "mac-a", "mac-b"])
        #expect(places.map(\.detail) == ["Studio", "Air", nil, nil])  // 只有同一项目绑在几台 Mac 上才写 Mac 名；其余只写项目名
        #expect(Set(places.map(\.id)).count == places.count)
    }

    @Test func Mac上只认本机的绑定_只绑在别的Mac上的项目在本机建工作区() async throws {
        let a = try await project("A"), b = try await project("B")
        let bindings = [
            binding(a, host: "mac-a", name: "Studio", folder: "app"), binding(a, host: "mac-b", name: "Air", folder: "app"),
            binding(b, host: "mac-b", name: "Air", folder: "site"),
        ]

        let places = ProjectFolders.launchPlaces(projects: [a, b], bindings: bindings, host: "mac-a", workMac: "mac-b")

        #expect(places.map(\.project.name) == ["A", "B"])
        #expect(places.map(\.host) == ["mac-a", "mac-a"])
        #expect(places.map(\.detail) == [nil, nil])
    }
}
