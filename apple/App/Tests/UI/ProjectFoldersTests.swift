import CueStore
import Foundation
import Testing
@testable import CuePad

/// 项目与文件夹（iOS 与 Mac 共用的规则）：新会话只列项目；项目操作菜单里的绑定与解除；手机上给项目选文件夹时的候选；绑定请求的进度。
/// 手机看不到 Mac 的完整路径，候选里只有文件夹名，由 Mac 按"取哪个会话的目录"解析成路径。
struct ProjectFoldersTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func project(_ name: String) async throws -> Project { try await store.createProject(name: name, color: "#111111") }

    private func binding(_ project: Project, host: String, name: String, folder: String) -> DirectoryBinding {
        DirectoryBinding(id: UUID(), projectID: project.id, hostID: host, hostName: name, folder: folder, createdAt: .now, modifiedAt: .now)
    }

    private func folder(_ name: String, host: String = "mac-a", sessions: Int = 1, latest: String? = nil, project: Project? = nil) -> SessionFolder {
        SessionFolder(hostID: host, folder: name, sessionID: latest ?? "\(host)-\(name)", projectID: project?.id, count: sessions)
    }

    // MARK: 新会话只列项目

    @Test func 新会话只列项目_按项目顺序_没绑文件夹的也列_绑在几台Mac上的每台一项() async throws {
        let a = try await project("A"), b = try await project("B"), c = try await project("C")
        let bindings = [
            binding(a, host: "mac-a", name: "Studio", folder: "app"), binding(a, host: "mac-b", name: "Air", folder: "app"),
            binding(b, host: "mac-a", name: "Studio", folder: "site"),
        ]

        let places = ProjectFolders.launchPlaces(projects: [a, b, c], bindings: bindings, host: nil)

        #expect(places.map(\.project.name) == ["A", "A", "B", "C"])
        #expect(places.map { $0.binding?.hostID } == ["mac-a", "mac-b", "mac-a", nil])
        #expect(places.map(\.detail) == ["Studio", "Air", nil, nil])  // 只有同一项目绑在几台 Mac 上才写 Mac 名；其余只写项目名
        #expect(Set(places.map(\.id)).count == places.count)
    }

    @Test func Mac上只认本机的绑定_只绑在别的Mac上的项目算没绑() async throws {
        let a = try await project("A"), b = try await project("B")
        let bindings = [
            binding(a, host: "mac-a", name: "Studio", folder: "app"), binding(a, host: "mac-b", name: "Air", folder: "app"),
            binding(b, host: "mac-b", name: "Air", folder: "site"),
        ]

        let places = ProjectFolders.launchPlaces(projects: [a, b], bindings: bindings, host: "mac-a")

        #expect(places.map(\.project.name) == ["A", "B"])
        #expect(places.map { $0.binding?.hostID } == ["mac-a", nil])
        #expect(places.map(\.detail) == [nil, nil])
    }

    // MARK: 项目页顶栏写的文件夹

    // MARK: 项目菜单

    // MARK: 手机上选文件夹的候选

    // MARK: 同名文件夹的建议

    // MARK: 引导在哪出现

    // MARK: 绑定请求的进度

    @Test func 进度_还在路上或已送到但绑定还没同步回来是正在绑_失败带原因_解除与别的项目不算() async throws {
        let a = try await project("A"), b = try await project("B")
        let executor = DeliveryExecutor(store: store, hostID: "mac-fail", onIssue: { _ in }) { _ in .failed("目录不存在：gone") }
        _ = try await store.requestBind(PiBind(project: a.id, folder: .besideSession("s1")), title: "A", on: "mac-wait")
        _ = try await store.requestBind(PiBind(project: a.id, folder: nil), title: "A", on: "mac-wait")
        _ = try await store.requestBind(PiBind(project: b.id, folder: .besideSession("s2")), title: "B", on: "mac-wait")
        #expect(ProjectFolders.bindProgress(of: a.id, in: try await store.deliveryRequests()) == .binding)
        #expect(ProjectFolders.bindProgress(of: UUID(), in: try await store.deliveryRequests()) == nil)

        let lone = try await project("Lone")
        let failing = try await store.requestBind(PiBind(project: lone.id, folder: .besideSession("s3")), title: "Lone", on: "mac-fail")
        try await executor.start()
        defer { Task { await executor.stop() } }
        _ = try await eventually(store, { try $0.deliveryRequest(failing.id)?.isOpen }) { $0 == false }
        #expect(ProjectFolders.bindProgress(of: lone.id, in: try await store.deliveryRequests()) == .failed("目录不存在：gone"))
    }
}
