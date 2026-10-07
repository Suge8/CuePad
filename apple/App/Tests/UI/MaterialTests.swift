import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务浮窗里加素材：挑一条灵感挂到任务下，或把图片存成一条灵感挂上；素材排在已有下级之后，不改变"灵感 / 任务"。
@MainActor
struct MaterialTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 挑一条灵感_挂成任务的素材_排在最后() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("修乱序", in: project.id)
        let sub = try await store.createTask("复现", under: task.id)
        let idea = try await store.createCard(in: project.id, body: "日志在 logs/0918.txt")
        let workspace = Workspace(services: rig.services)

        try await workspace.attach(idea.id, to: task.id)

        #expect(try await store.children(of: task.id).map(\.id) == [sub.id, idea.id])
        #expect(try await store.card(idea.id)?.isTask == false)
        #expect(try await store.cards(in: project.id).isEmpty)
    }

    @Test func 图片存成一条灵感_挂在任务下() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("修乱序", in: project.id)
        let workspace = Workspace(services: rig.services)
        let hash = try rig.services.images.store(pngData())

        try await workspace.attachImages([pngData()], to: task)

        let material = try #require(try await store.children(of: task.id).first)
        #expect(material.body == "![](cuepad://img/\(hash))")
        #expect(material.projectID == project.id && !material.isTask)
    }
}
