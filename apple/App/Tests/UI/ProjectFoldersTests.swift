import CueStore
import Foundation
import Testing
@testable import CuePad

/// 项目与文件夹（iOS 与 Mac 共用的规则）：新会话只列项目；项目操作菜单里的绑定与解除；手机上给项目选文件夹时的候选；绑定请求的进度。
/// 手机看不到 Mac 的完整路径，候选里只有文件夹名，由 Mac 按"取哪个会话的目录"解析成路径。
@MainActor
struct ProjectFoldersTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func project(_ name: String) async throws -> Project { try await store.createProject(name: name, color: "#111111") }

    private func binding(_ project: Project, host: String, name: String, folder: String) -> DirectoryBinding {
        DirectoryBinding(id: UUID(), projectID: project.id, hostID: host, hostName: name, folder: folder, createdAt: .now, modifiedAt: .now)
    }

    private func session(_ id: String, folder: String?, host: String = "mac-a", project: Project? = nil) -> PiSessionListItem {
        PiSessionListItem(
            state: PiSessionState(
                id: UUID(), sessionID: id, hostID: host, title: id, projectID: project?.id, state: .known(.settled), detail: nil, folder: folder,
                lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now, modifiedAt: .now),
            project: project)
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

    // MARK: 项目菜单

    @Test func 项目菜单_没绑是绑定_绑了是换与解除_手机上绑在几台Mac上时解除按Mac分开() async throws {
        let a = try await project("A")
        let studio = binding(a, host: "mac-a", name: "Studio", folder: "app"), air = binding(a, host: "mac-b", name: "Air", folder: "app")

        let none = ProjectFolders.menu(for: a.id, bindings: [], host: nil)
        #expect(none.bindTitle == "绑定文件夹…" && none.unbinds.isEmpty)

        let one = ProjectFolders.menu(for: a.id, bindings: [studio], host: nil)
        #expect(one.bindTitle == "换文件夹…" && one.unbinds.map(\.title) == ["解除绑定"] && one.unbinds.map(\.binding) == [studio])

        let two = ProjectFolders.menu(for: a.id, bindings: [studio, air], host: nil)
        #expect(two.unbinds.map(\.title) == ["解除绑定 · Studio", "解除绑定 · Air"])

        // Mac 上只管本机这一条；只绑在别的 Mac 上时对这台 Mac 仍是"绑定"
        let mac = ProjectFolders.menu(for: a.id, bindings: [studio, air], host: "mac-a")
        #expect(mac.bindTitle == "换文件夹…" && mac.unbinds.map(\.title) == ["解除绑定"] && mac.unbinds.map(\.binding) == [studio])
        #expect(ProjectFolders.menu(for: a.id, bindings: [air], host: "mac-a").bindTitle == "绑定文件夹…")

        // 别的项目的绑定不算
        let b = try await project("B")
        #expect(ProjectFolders.menu(for: b.id, bindings: [studio, air], host: nil).unbinds.isEmpty)
    }

    // MARK: 手机上选文件夹的候选

    @Test func 候选_来自各Mac上跑过Agent的文件夹_最近的在前_同Mac同名去重() async throws {
        let a = try await project("A")
        let items = [
            session("s1", folder: "app"), session("s2", folder: "site", host: "mac-b"), session("s3", folder: "app"),
            session("s4", folder: nil), session("s5", folder: "app", host: "mac-b"),
        ]
        let known = [binding(a, host: "mac-a", name: "Studio", folder: "elsewhere"), binding(a, host: "mac-b", name: "Air", folder: "elsewhere")]

        let candidates = ProjectFolders.candidates(sessions: items, bindings: known, projects: [a], excluding: nil)

        #expect(candidates.map { "\($0.hostID)/\($0.folder)" } == ["mac-a/app", "mac-b/site", "mac-b/app", "mac-a/elsewhere", "mac-b/elsewhere"])
        #expect(candidates.map(\.hostName) == ["Studio", "Air", "Air", "Studio", "Air"])
        #expect(candidates[0].target == .besideSession("s1") && candidates[2].target == .besideSession("s5"))
        #expect(candidates[3].target == .project(a.id))  // 没有会话跑过、但别的项目绑着的目录，让那台 Mac 从那个项目取
    }

    @Test func 候选_当前项目已绑的不再列_标出已被哪个项目用着_不认识的Mac没有名字() async throws {
        let a = try await project("A"), b = try await project("B")
        let items = [session("s1", folder: "app", project: b), session("s2", folder: "site"), session("s3", folder: "other", host: "mac-x")]
        let known = [binding(a, host: "mac-a", name: "Studio", folder: "site"), binding(b, host: "mac-a", name: "Studio", folder: "app")]

        let candidates = ProjectFolders.candidates(sessions: items, bindings: known, projects: [a, b], excluding: a.id)

        #expect(candidates.map(\.folder) == ["app", "other"])  // site 已经绑给 A 了
        #expect(candidates.map(\.usedBy) == ["B", nil])
        #expect(candidates.map(\.hostName) == ["Studio", nil])
    }

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
        for _ in 0..<300 {
            if try await store.deliveryRequest(failing.id)?.isOpen == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ProjectFolders.bindProgress(of: lone.id, in: try await store.deliveryRequests()) == .failed("目录不存在：gone"))
    }
}
