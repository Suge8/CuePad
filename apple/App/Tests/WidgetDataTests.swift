import CueStore
import Foundation
import Testing
@testable import CuePad

/// 小组件与分享扩展读的快照：主 App 跟随资料库变化写进共享容器。
struct WidgetDataTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var snapshots: URL { services.location.snapshotsDirectory }

    @Test func 默认项目快照按最近修改排最多五张_带名字总数与首行标题() async throws {
        for index in 1...7 {
            _ = try await services.store.createCard(body: "卡片 \(index)\n后面的行")
            try await Task.sleep(for: .milliseconds(2))  // 修改时间是毫秒：一张比一张新
        }
        _ = try await services.store.createCard(body: "![](cuepad://file/\(String(repeating: "a", count: 64)))")
        let project = try await services.store.createProject(name: "P", color: "#000000")
        _ = try await services.store.createCard(in: project.id, body: "不在默认项目")

        try await services.writeSnapshots()

        let home = try #require(Snapshots.read(DefaultProjectSnapshot.self, from: snapshots))
        #expect(home.name == "默认")
        #expect(home.total == 8)
        #expect(home.cards.count == 5)
        #expect(home.cards.first?.title == "", "刚建的纯图片卡最新，没有文字标题")
        #expect(home.cards.dropFirst().map(\.title) == ["卡片 7", "卡片 6", "卡片 5", "卡片 4"])
    }

    #if os(iOS)
    // 跟着库改快照只有 iPhone（`AppServices.start`）：它的那份 Cue 现状同一次读带着小组件另要的（`CueFeed`），Mac 的不带
    @Test func 资料库变化后快照自动更新() async throws {
        services.startSnapshots()
        defer { services.cancelBackgroundWork() }

        _ = try await services.store.createProject(name: "新项目", color: "#abcdef")
        _ = try await services.store.createCard(body: "默认项目里的")

        try await eventually("快照里有新项目与默认项目里的灵感") {
            Snapshots.read(ProjectsSnapshot.self, from: snapshots)?.projects.map(\.name).contains("新项目") == true
                && Snapshots.read(DefaultProjectSnapshot.self, from: snapshots)?.cards.map(\.title) == ["默认项目里的"]
        }
    }
    #endif

    @Test func 进入后台前先跑完登记的落盘_再刷新快照() async throws {
        var order: [String] = []
        let token = services.addBackgroundFlush {
            try? await Task.sleep(for: .milliseconds(50))
            order.append("草稿")
        }
        services.addBackgroundFlush { order.append("另一处") }
        let removed = services.addBackgroundFlush { order.append("已注销") }
        services.removeBackgroundFlush(removed)
        _ = try await services.store.createCard(body: "刚写的")

        await services.prepareForBackground()

        #expect(Set(order) == ["草稿", "另一处"])
        #expect(order.count == 2)
        #expect(Snapshots.read(DefaultProjectSnapshot.self, from: snapshots)?.cards.map(\.title) == ["刚写的"])
        services.removeBackgroundFlush(token)
    }

    /// 小组件、通知与旧版本写出的链接：认得的解析与生成互逆，不认识的忽略。
    @Test(arguments: [
        ("cuepad://speak", DeepLink.speak),
        ("cuepad://project/6f0c1a7e-0000-4000-8000-000000000002", DeepLink.project(UUID(uuidString: "6f0c1a7e-0000-4000-8000-000000000002")!)),
        ("cuepad://card/6f0c1a7e-0000-4000-8000-000000000003", DeepLink.card(UUID(uuidString: "6f0c1a7e-0000-4000-8000-000000000003")!)),
        ("cuepad://cue", DeepLink.cue),
        ("cuepad://session/6f0c1a7e-0000-4000-8000-000000000004", DeepLink.session(UUID(uuidString: "6f0c1a7e-0000-4000-8000-000000000004")!)),
        ("https://example.com", nil), ("cuepad://unknown", nil), ("cuepad://project/not-a-uuid", nil), ("cuepad://project", nil), ("cuepad://capture", nil),
    ] as [(String, DeepLink?)])
    func 深链接解析与生成互逆_不认识的忽略(text: String, link: DeepLink?) {
        let url = URL(string: text)!
        #expect(DeepLink(url: url) == link)
        if let link { #expect(link.url == url) }
        services.handle(url: url)
        #expect(services.pendingDeepLink == link)
    }
}
