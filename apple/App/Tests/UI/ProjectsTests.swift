import CueStore
import Foundation
import SwiftUI
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

    /// 新库第一次打开：落在 Cue 页（没有"还没有项目"的空页），库里已有默认项目；
    /// 只记下（⌘⇧N 同一个）不选项目，灵感进它。
    @Test func 新库首屏是Cue页_只记下的灵感进默认项目() async throws {
        let workspace = Workspace(services: services)
        let catalog = observing(workspace)
        defer { catalog.cancel() }
        try await eventually("目录里只有默认项目") { workspace.catalog?.projects.map(\.id) == [Project.defaultID] }
        #expect(workspace.root == .cue)

        workspace.cue.draft = ComposerDraft(text: "周末读完第三章")
        await workspace.note(from: Bindable(workspace.cue).draft)?.value
        #expect(try await store.cards(in: Project.defaultID).map(\.body) == ["周末读完第三章"])
        #expect(workspace.notice?.text.visible == "已记到 默认" && workspace.notice?.link == .project(Project.defaultID))
    }

    @Test func 启动回到上次的项目_失效时回到Cue页_数字键按当下顺序取() async throws {
        // 保存的项目不存在：清掉失效的设置，首屏是 Cue 页
        _ = try await store.createProject(name: "A", color: "#000000")
        let pinned = try await store.createProject(name: "B", color: "#000000")
        try await store.updateProject(pinned.id) { $0.isPinned = true }
        services.settings.currentProject = UUID()
        let workspace = Workspace(services: services)
        let catalog = observing(workspace)
        defer { catalog.cancel() }
        try await eventually("目录读到三个项目，失效设置清掉") { workspace.catalog?.projects.count == 3 && services.settings.currentProject == nil }
        #expect(workspace.root == .cue)

        // 打开过的项目：下次打开回到它
        services.settings.currentProject = pinned.id
        let fresh = Workspace(services: services)
        let freshCatalog = observing(fresh)
        defer { freshCatalog.cancel() }
        #expect(fresh.root == .project(pinned.id))
        let last = try await store.createProject(name: "C", color: "#000000")
        try await store.updateProject(last.id) { $0.isPinned = true }
        try await eventually("fresh.catalog?.projects.first?.id == last.id") { fresh.catalog?.projects.first?.id == last.id }

        // ⌘N 打开侧栏里此刻的第 N 个：顺序变了不能还绑在旧顺序上；没有那么多个就不动
        fresh.showProject(number: 1)
        #expect(fresh.root == .project(last.id) && services.settings.currentProject == last.id)
        fresh.showProject(number: 3)
        let third = try #require(fresh.catalog?.projects[2].id)
        #expect(fresh.root == .project(third) && third != last.id)
        fresh.showProject(number: 9)
        #expect(fresh.root == .project(third))

        // 当前项目进了回收站：回到 Cue 页；默认项目删不掉
        services.settings.currentProject = third
        for project in try await store.projects() where !project.isDefault { try await store.trashProject(project.id) }
        await #expect(throws: CueStoreError.defaultProjectUndeletable) { try await store.trashProject(Project.defaultID) }
        let only = Workspace(services: services)
        await only.reconcileCurrentProject()
        #expect(only.root == .cue && services.settings.currentProject == nil)
    }

    @Test func 往失效项目存东西_落到默认项目_写入时被删则纠正并提示() async throws {
        let trashed = try await store.createProject(name: "A", color: "#000000")
        try await store.trashProject(trashed.id)
        let workspace = Workspace(services: services)

        for target in [UUID(), trashed.id] { #expect(try await workspace.createCard(body: "想法", in: target).projectID == Project.defaultID) }
        #expect(try await store.cards(in: Project.defaultID).map(\.body) == ["想法", "想法"])
        #expect(try await workspace.createTask("跟进", in: UUID()).projectID == Project.defaultID)
        let live = try await store.createProject(name: "B", color: "#000000")
        #expect(try await workspace.createCard(body: "想法", in: live.id).projectID == live.id)

        // 竞态：选中项目之后、写入之前项目被删——Store 在写事务里拒绝，入口回落并提示
        workspace.show(.project(live.id))
        let target = workspace.currentProject
        try await store.trashProject(live.id)
        let card = try await workspace.createCard(body: "晚了一步", in: try #require(target))
        #expect(card.projectID == Project.defaultID && services.settings.currentProject == nil && workspace.notice?.isError == true)
        workspace.notice = nil
        let doomed = try await store.createProject(name: "C", color: "#000000")
        try await store.trashProject(doomed.id)
        let task = try await workspace.createTask("跟进", in: doomed.id)
        #expect(task.projectID == Project.defaultID && workspace.notice?.isError == true)
    }
}
#endif

#if os(iOS)
/// iPhone/iPad 上"现在在哪个项目"只有一份：从导航路径推出（`Workspace.currentProject`）。
struct ProjectsNavigationTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func navigation() -> Workspace { Workspace(services: app.services) }

    @Test func 书架点进项目_新建落在这个项目_iPad恢复窗口_深链进项目() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let trashed = try await store.createProject(name: "装修", color: "#000000")
        try await store.trashProject(trashed.id)
        let workspace = Workspace(services: app.services)

        let phone = navigation()
        phone.select(.shelf)  // 底部那一排的"项目"
        phone.push(.project(project.id))  // 书架上的项目卡
        phone.push(.progress)  // 项目页的"已完成 N"
        #expect(try await workspace.createTask("补重连用例", in: try #require(phone.currentProject)).projectID == project.id)
        phone.select(.progress)  // 侧栏的"进展"：不在哪个项目里
        #expect(phone.currentProject == nil)
        phone.open(DeepLink.project(project.id))
        #expect(phone.currentProject == project.id)

        // iPad 恢复窗口：选回上次的项目；已进回收站时留在打开 App 的那一页；侧栏选别的页后不再算在项目里
        let pad = navigation()
        pad.restore(project: project.id)
        #expect(pad.root == .project(project.id))
        pad.push(.card(UUID()))
        pad.restore(project: project.id)  // 窗口宽窄变化、分栏重建
        #expect(pad.path.count == 1 && pad.currentProject == project.id)
        pad.select(.progress)
        #expect(pad.currentProject == nil)
        let gone = navigation()
        gone.restore(project: trashed.id)
        #expect(gone.root == .cue)
    }
}
#endif
