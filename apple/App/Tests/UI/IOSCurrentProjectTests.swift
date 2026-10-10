#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// iPhone/iPad 上"现在在哪个项目"只有一份：从导航路径推出（`Navigation.currentProject`）。书架点进项目只改路径
/// （`NavigationLink(value:)`），深链、提示点击、iPad 侧栏、⌘1–9 也只改路径；随手记、任务页新建任务、⌘N 的默认落点都读它。
@MainActor
struct IOSCurrentProjectTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func navigation(_ layout: Navigation.Layout) -> Navigation {
        let navigation = Navigation(settings: app.services.settings)
        navigation.layout = layout
        return navigation
    }

    @Test func iPhone从书架点进项目再进任务页_新建任务落在这个项目() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let workspace = Workspace(services: app.services)
        let navigation = navigation(.tabs)

        navigation.projectsPath.append(.project(project.id))  // 书架上的项目卡
        navigation.push(.tasks)  // 项目页的"已完成 N"
        let task = try await workspace.createTask("补重连用例", in: navigation.currentProject)

        #expect(task.projectID == project.id)
        navigation.projectsPath = [.tasks]  // 书架上的"全部任务"：不在哪个项目里
        #expect(navigation.currentProject == nil)
    }

    /// iPad 恢复窗口：选回上次侧栏选中的项目；那个项目已进回收站时留在书架，不停在一张空的项目页上。
    @Test func iPad恢复窗口_选回上次的项目_已进回收站时留在书架() async throws {
        let kept = try await store.createProject(name: "圆桌", color: "#000000")
        let trashed = try await store.createProject(name: "装修", color: "#000000")
        try await store.trashProject(trashed.id)
        let catalog = try await ProjectCatalog.read(from: store)

        let restored = navigation(.split)
        restored.restore(project: kept.id, catalog: catalog)
        #expect(restored.splitRoot == .project(kept.id))

        let gone = navigation(.split)
        gone.restore(project: trashed.id, catalog: catalog)
        #expect(gone.splitRoot == .shelf)
    }

    @Test func 深链与提示点击进项目_iPad侧栏选别的页后不再算在项目里() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let phone = navigation(.tabs)
        phone.open(DeepLink.project(project.id))
        #expect(phone.currentProject == project.id)

        let pad = navigation(.split)
        pad.show(project: project.id)
        pad.push(.card(UUID()))
        #expect(pad.currentProject == project.id)  // 项目页上打开的卡
        pad.select(.tasks)
        #expect(pad.currentProject == nil)
    }
}
#endif
