import CueStore
import Foundation
import Testing
@testable import CuePad

/// 小组件与分享扩展读的快照：主 App 跟随资料库变化写进共享容器。
@MainActor
struct WidgetDataTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var snapshots: URL { services.location.snapshotsDirectory }

    @Test func 未分类快照按最近修改排最多五张_带总数与首行标题() async throws {
        for index in 1...7 {
            let card = try await services.store.createCard(in: nil, body: "卡片 \(index)\n后面的行")
            try await services.store.updateCard(card.id) { $0.modifiedAt = Date(timeIntervalSince1970: Double(index)) }
        }
        _ = try await services.store.createCard(in: nil, body: "![](cuepad://img/\(String(repeating: "a", count: 64)))")
        let project = try await services.store.createProject(name: "P", color: "#000000")
        _ = try await services.store.createCard(in: project.id, body: "不在未分类")

        try await services.writeSnapshots()

        let unfiled = try #require(Snapshots.readUnfiled(from: snapshots))
        #expect(unfiled.total == 8)
        #expect(unfiled.cards.count == 5)
        #expect(unfiled.cards.first?.title == "", "刚建的纯图片卡最新，没有文字标题")
        #expect(unfiled.cards.dropFirst().map(\.title) == ["卡片 7", "卡片 6", "卡片 5", "卡片 4"])
    }

    @Test func 资料库变化后快照自动更新() async throws {
        services.startSnapshots()
        defer { services.cancelBackgroundWork() }

        _ = try await services.store.createProject(name: "新项目", color: "#abcdef")
        _ = try await services.store.createCard(in: nil, body: "未分类里的")

        await eventually {
            Snapshots.readProjects(from: snapshots)?.projects.map(\.name) == ["新项目"]
                && Snapshots.readUnfiled(from: snapshots)?.cards.map(\.title) == ["未分类里的"]
        }
        #expect(Snapshots.readProjects(from: snapshots)?.projects.map(\.name) == ["新项目"])
        #expect(Snapshots.readUnfiled(from: snapshots)?.cards.map(\.title) == ["未分类里的"])
    }

    /// 小组件刷新有系统预算：未分类显示的内容没变时不重写快照、不刷新（重写会让下面的哨兵值被覆盖）。
    @Test func 未分类显示的内容没变时不重写未分类快照() async throws {
        services.startSnapshots()
        defer { services.cancelBackgroundWork() }
        _ = try await services.store.createCard(in: nil, body: "未分类里的")
        let project = try await services.store.createProject(name: "P", color: "#000000")
        await eventually {
            Snapshots.readUnfiled(from: snapshots)?.total == 1 && Snapshots.readProjects(from: snapshots)?.projects.map(\.name) == ["P"]
        }
        let sentinel = UnfiledSnapshot(cards: [], total: 999)
        try Snapshots.write(sentinel, to: snapshots)

        let other = try await services.store.createCard(in: project.id, body: "项目里的")
        try await services.store.updateCard(other.id) { $0.body = "项目里的，改过" }
        try await services.store.updateProject(project.id) { $0.name = "P2" }
        await eventually { Snapshots.readProjects(from: snapshots)?.projects.map(\.name) == ["P2"] }

        #expect(Snapshots.readProjects(from: snapshots)?.projects.map(\.name) == ["P2"])
        #expect(Snapshots.readUnfiled(from: snapshots) == sentinel)
    }

    @Test func 进入后台前先跑完登记的落盘_再刷新快照() async throws {
        var order: [String] = []
        let token = services.addBackgroundFlush {
            try? await Task.sleep(for: .milliseconds(50))
            order.append("草稿")
        }
        services.addBackgroundFlush { order.append("另一处") }
        let removed = services.addBackgroundFlush { order.append("已注销") }
        services.removeBackgroundFlush(removed)
        _ = try await services.store.createCard(in: nil, body: "刚写的")

        await services.prepareForBackground()

        #expect(Set(order) == ["草稿", "另一处"])
        #expect(order.count == 2)
        #expect(Snapshots.readUnfiled(from: snapshots)?.cards.map(\.title) == ["刚写的"])
        services.removeBackgroundFlush(token)
    }

    @Test(arguments: [
        ("cuepad://capture", DeepLink.capture(project: nil)),
        ("cuepad://capture?project=6f0c1a7e-0000-4000-8000-000000000001", DeepLink.capture(project: UUID(uuidString: "6f0c1a7e-0000-4000-8000-000000000001"))),
        ("cuepad://project/6f0c1a7e-0000-4000-8000-000000000002", DeepLink.project(UUID(uuidString: "6f0c1a7e-0000-4000-8000-000000000002")!)),
        ("cuepad://card/6f0c1a7e-0000-4000-8000-000000000003", DeepLink.card(UUID(uuidString: "6f0c1a7e-0000-4000-8000-000000000003")!)),
    ])
    func 深链接解析与生成互逆(text: String, link: DeepLink) {
        #expect(DeepLink(url: URL(string: text)!) == link)
        #expect(link.url == URL(string: text))
    }

    @Test(arguments: ["https://example.com", "cuepad://unknown", "cuepad://project/not-a-uuid", "cuepad://project", "cuepad://capture?project=x"])
    func 不认识的链接被忽略(text: String) {
        #expect(DeepLink(url: URL(string: text)!) == nil)
        services.handle(url: URL(string: text)!)
        #expect(services.pendingDeepLink == nil)
    }
}
