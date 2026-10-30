#if os(macOS)
import CueStore
import CueSync
import Foundation
import Testing
@testable import CuePad

@testable import CuePi

extension MacSyncTests {
    // 绑定由 Mac 执行（只有它有完整路径），写入只有这一条：本机的目录绑定

    func bound(_ bind: PiBind) async throws -> DeliveryRequest {
        try await services.executor.start()
        let request = try await services.store.requestBind(bind, title: "App", on: TestApp.hostID)
        return try await awaitFinished(request.id)
    }

    /// 绑定取某个会话的工作目录，或另一个项目已绑的目录（换绑覆盖旧的），没有文件夹就是解除；都写成本机的目录绑定，不写发送记录。
    @Test func 绑定_取会话的工作目录或别的项目的目录_换绑覆盖_没有文件夹就是解除() async throws {
        let app = try folder("app"), second = try folder("second")
        _ = try await indexed("s1", cwd: app)
        let store = services.store
        let source = try await store.createProject(name: "源", color: "#000000")
        let project = try await store.createProject(name: "App", color: "#000000")
        try await store.setDirectory(second.path, for: source.id)
        defer { services.cancelBackgroundWork() }

        #expect(try await bound(PiBind(project: project.id, folder: .besideSession("s1"))).status == .known(.succeeded))
        #expect(try await store.directory(of: project.id) == app.path)

        #expect(try await bound(PiBind(project: project.id, folder: .project(source.id))).status == .known(.succeeded))
        #expect(try await store.directory(of: project.id) == second.path)

        #expect(try await bound(PiBind(project: project.id, folder: nil)).status == .known(.succeeded))
        #expect(try await store.directory(of: project.id) == nil)
        #expect(try await store.directory(of: source.id) == second.path)
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    /// 项目记录可能还没同步到这台 Mac（手机刚新建项目就带着文件夹）：绑定按项目 id 记，记录晚到也对得上，不因此失败。
    @Test func 绑定_项目记录还没到本机也成功() async throws {
        let app = try folder("app")
        _ = try await indexed("s1", cwd: app)
        let unseen = UUID()
        defer { services.cancelBackgroundWork() }

        let done = try await bound(PiBind(project: unseen, folder: .besideSession("s1")))

        #expect(done.status == .known(.succeeded))
        #expect(try await services.store.directory(of: unseen) == app.path)
    }

    @Test func 绑定_找不到文件夹时按失败写回_原因可读_不改现有绑定() async throws {
        let existing = try folder("existing")
        _ = try await indexed("gone-folder", cwd: rig.directory.appending(path: "work/gone", directoryHint: .isDirectory))
        let project = try await services.store.createProject(name: "App", color: "#000000")
        let bare = try await services.store.createProject(name: "无目录", color: "#000000")
        try await services.store.setDirectory(existing.path, for: project.id)
        defer { services.cancelBackgroundWork() }

        let noSession = try await bound(PiBind(project: project.id, folder: .besideSession("nope")))
        #expect(noSession.status == .known(.failed) && noSession.reason?.text == SendError.piSessionNotOnThisMac.localizedDescription)
        let missing = try await bound(PiBind(project: project.id, folder: .besideSession("gone-folder")))
        #expect(missing.status == .known(.failed) && missing.reason?.text == "目录不存在：gone")
        let unbound = try await bound(PiBind(project: project.id, folder: .project(bare.id)))
        #expect(unbound.status == .known(.failed) && unbound.reason?.text == SendError.noCodeDirectory("无目录").localizedDescription)
        #expect(try await services.store.directory(of: project.id) == existing.path)
    }

    /// 目录被删或改名了：不启动 Pi，按失败写回，原因写目录末段名。
    @Test func 目录不存在时不启动_按失败写回() async throws {
        _ = try await indexed("s1", cwd: rig.directory.appending(path: "work/gone", directoryHint: .isDirectory))
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(rig.directory.appending(path: "work/moved").path, for: project.id)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let send = try await services.store.requestDelivery(
            "接着做", to: SendTarget(kind: .piSession, name: "修好登录", ref: "s1"), on: TestApp.hostID)
        let resumed = try await awaitFinished(send.id)
        #expect(resumed.status == .known(.failed) && resumed.reason?.text == "目录不存在：gone")
        let start = try await launched(PiLaunch(project: project.id, prompt: nil, token: "tok-4"), title: "App")
        #expect(start.status == .known(.failed) && start.reason?.text == "目录不存在：moved")
        #expect(rig.host.calls.isEmpty)
    }

    /// 项目在哪台 Mac 上绑定了目录（只带目录末段名）同步给手机：Mac 绑定、解绑后随之写、删。
    @Test
    func 目录绑定随绑定与解绑同步() async throws {
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.startDirectoryBindings()
        defer { services.cancelBackgroundWork() }

        try await services.store.setDirectory("/Users/someone/work/app", for: project.id)
        var bound: [DirectoryBinding] = []
        for try await bindings in services.store.observe({ try $0.directoryBindings() }) where !bindings.isEmpty {
            bound = bindings
            break
        }
        #expect(bound.map(\.projectID) == [project.id] && bound.map(\.hostID) == [TestApp.hostID] && bound.map(\.folder) == ["app"])

        try await services.store.setDirectory(nil, for: project.id)
        for try await bindings in services.store.observe({ try $0.directoryBindings() }) where bindings.isEmpty { break }
    }
}
#endif
