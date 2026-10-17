import CueStore
import Foundation
import Testing
@testable import CuePad

/// "现在在哪个项目"与往哪存：Mac 的首屏、⌘1–9、新建落点，手机的导航路径；项目失效（不存在、进了回收站、写入时被删）时回落并提示，不吞错。
#if os(macOS)
struct ProjectsTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    /// 跟着工作区的订阅（App 启动时同一条路），项目目录在其中。
    private func observing(_ workspace: Workspace) -> Task<Void, Never> {
        Task { await workspace.follow() }
    }

    @Test func 启动落在哪个项目_跟着侧栏顺序_数字键按当下顺序取_失效时回落() async throws {
        // 保存的项目不存在：首屏是侧栏第一个有效项目（置顶的在前），并清掉失效的设置
        _ = try await store.createProject(name: "A", color: "#000000")
        let pinned = try await store.createProject(name: "B", color: "#000000")
        try await store.updateProject(pinned.id) { $0.isPinned = true }
        services.settings.currentProject = UUID()
        let workspace = Workspace(services: services)
        let catalog = observing(workspace)
        defer { catalog.cancel() }
        try await eventually("workspace.catalog?.projects.count == 2 && services.settings.currentProject == nil") { workspace.catalog?.projects.count == 2 && services.settings.currentProject == nil }
        #expect(workspace.page == .project(pinned.id))

        // 没打开过项目：项目顺序变了首屏跟着变、不记成"上次打开"，用户切换才记下
        let fresh = Workspace(services: services)
        services.settings.currentProject = nil
        let freshCatalog = observing(fresh)
        defer { freshCatalog.cancel() }
        try await eventually("fresh.catalog?.projects.first?.id == pinned.id") { fresh.catalog?.projects.first?.id == pinned.id }
        #expect(fresh.page == .project(pinned.id) && services.settings.currentProject == nil)
        let last = try await store.createProject(name: "C", color: "#000000")
        try await store.updateProject(last.id) { $0.isPinned = true }
        try await eventually("fresh.catalog?.projects.first?.id == last.id") { fresh.catalog?.projects.first?.id == last.id }
        #expect(fresh.page == .project(last.id))

        // ⌘N 打开侧栏里此刻的第 N 个：顺序变了不能还绑在旧顺序上；没有那么多个就不动
        fresh.showProject(number: 1)
        #expect(fresh.page == .project(last.id) && services.settings.currentProject == last.id)
        fresh.showProject(number: 3)
        let third = try #require(fresh.catalog?.projects[2].id)
        #expect(fresh.page == .project(third) && third != last.id)
        fresh.showProject(number: 9)
        #expect(fresh.page == .project(third))

        // 当前项目进了回收站：回落到未分类
        services.settings.currentProject = third
        for project in try await store.projects() { try await store.trashProject(project.id) }
        let only = Workspace(services: services)
        await only.reconcileCurrentProject()
        #expect(only.page == .unfiled && services.settings.currentProject == nil)
    }

    @Test func 往失效项目存东西_落到未分类或全局_写入时被删则纠正并提示() async throws {
        let trashed = try await store.createProject(name: "A", color: "#000000")
        try await store.trashProject(trashed.id)
        let workspace = Workspace(services: services)

        for target in [UUID(), trashed.id] { #expect(try await workspace.createCard(body: "想法", in: target).projectID == nil) }
        #expect(try await store.cards(in: nil).map(\.body) == ["想法", "想法"])
        #expect(try await workspace.createTask("跟进", in: UUID()).projectID == nil)
        let live = try await store.createProject(name: "B", color: "#000000")
        #expect(try await workspace.createCard(body: "想法", in: live.id).projectID == live.id)

        // 竞态：选中项目之后、写入之前项目被删——Store 在写事务里拒绝，入口回落并提示
        services.settings.currentProject = live.id
        let target = workspace.currentProject
        try await store.trashProject(live.id)
        let card = try await workspace.createCard(body: "晚了一步", in: target)
        #expect(card.projectID == nil && services.settings.currentProject == nil && workspace.notice?.isError == true)
        workspace.notice = nil
        let doomed = try await store.createProject(name: "C", color: "#000000")
        try await store.trashProject(doomed.id)
        let task = try await workspace.createTask("跟进", in: doomed.id)
        #expect(task.projectID == nil && workspace.notice?.isError == true)
    }
}
#endif

#if os(iOS)
/// iPhone/iPad 上"现在在哪个项目"只有一份：从导航路径推出（`Navigation.currentProject`）。
struct ProjectsNavigationTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func navigation() -> Navigation { Navigation(settings: app.services.settings) }

    @Test func 书架点进项目_新建落在这个项目_iPad恢复窗口_深链进项目() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let trashed = try await store.createProject(name: "装修", color: "#000000")
        try await store.trashProject(trashed.id)
        let catalog = try await ProjectCatalog.read(from: store)
        let workspace = Workspace(services: app.services)

        let phone = navigation()
        phone.select(.shelf)  // 侧栏的"全部项目"
        phone.push(.project(project.id))  // 书架上的项目卡
        phone.push(.tasks)  // 项目页的"已完成 N"
        #expect(try await workspace.createTask("补重连用例", in: phone.currentProject).projectID == project.id)
        phone.select(.tasks)  // 侧栏的"任务"：不在哪个项目里
        #expect(phone.currentProject == nil)
        phone.open(DeepLink.project(project.id))
        #expect(phone.currentProject == project.id)

        // iPad 恢复窗口：选回上次的项目；已进回收站时留在打开 App 的那一页；侧栏选别的页后不再算在项目里
        let pad = navigation()
        pad.restore(project: project.id, catalog: catalog)
        #expect(pad.root == .project(project.id))
        pad.push(.card(UUID()))
        pad.restore(project: project.id, catalog: catalog)  // 窗口宽窄变化、分栏重建
        #expect(pad.path.count == 1 && pad.currentProject == project.id)
        pad.select(.tasks)
        #expect(pad.currentProject == nil)
        let gone = navigation()
        gone.restore(project: trashed.id, catalog: catalog)
        #expect(gone.root == .cue)
    }
}
#endif
