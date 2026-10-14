#if DEBUG
import CueStore
import CueText
import SwiftUI

/// 演示库里的 Cue（`-CuePadScene cue`、`cuememory`，配 `-CuePadDemo YES`）：启用在演示 Mac 上，跟进圆桌的"乱序"（步骤在 Agent 会话里跑，
/// 部署那一步发来一张截图、在等你收下）与 CuePad 的"导入旧数据"（会话出错）；"README 截图换成 Swift 版"刚做完。
/// 对话里有你的话（一句带图）、Cue 的话、折起的动态与一条"等你"（正文带一段测试输出）；atlas 会话里有一句 Cue 发的话；记忆有钉住的与其他，还有一条忘掉的。
/// 上次离开 Cue 页记在两小时前，回到页里有"你不在时"。
/// `-CuePadCuePresence <thinking|asleep|disabled>`：你的最后一句已交给 Cue 还没回（在想）、没交出去超过 30 秒（它住的那台 Mac 不在线，在睡觉）、没启用。
extension DebugScene {
    static func seedCue(_ services: AppServices) async {
        let store = services.store
        guard (try? await store.cueMessages(limit: 1).isEmpty) == true else { return }
        let presence = defaults.string(forKey: "CuePadCuePresence")
        services.settings.cueSeenAt = .now.addingTimeInterval(-7_200)
        do {
            _ = try await store.updateCueProfile { profile in
                profile.hostID = "demo-mac"
                profile.enabledAt = presence == "disabled" ? nil : .now
            }
            let tasks = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks)
            func task(_ prefix: String) -> Card? { tasks.first { $0.parentID == nil && $0.body.hasPrefix(prefix) } }
            let order = task("发言轮次"), importing = task("导入旧数据"), panel = task("README 截图")
            for card in [order, importing, panel].compactMap(\.self) { _ = try await store.setCueFollows(card.id, true) }
            if let importing { try await store.linkCard(importing.id, toSession: "billing") }
            if let panel { try await store.setStatus(panel.id, .done) }
            await seedEvidence(store)
            // Cue 发进 atlas 会话的一句（还在路上）：会话页的气泡上标着 Cue
            _ = try await store.requestDelivery(
                "排序改完后把 scheduler 的测试全跑一遍，结果贴给我", to: SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), on: "demo-mac", cue: true)

            func you(_ text: String) async throws {
                let message = try await store.addCueMessage(.you, text: text)
                try await store.markCueMessagesDelivered([message.id])
            }
            try await you("圆桌那个 5 人以上乱序的 bug 交给你，修好之后部署到预发")
            _ = try await store.addCueMessage(.cue, text: "好。拆成四步：复现、改成按首次加入时间排序、补 3 个重连用例、部署到预发。第一步已经复现了，现在在改排序。", task: order?.id)
            for note in [
                "看了圆桌：复现乱序完成，原因是重连的人拿到了新的加入时间",
                "让 atlas 改成按首次加入时间排序，正在跑 scheduler 的测试",
                "CuePad 导入旧数据的会话出错了：模型拒绝了请求（prompt 太长），等你回来再说",
            ] { _ = try await store.addCueMessage(.note, text: note) }
            let shot = CueFormat.imageMarkup(id: try store.files.store(swatchPNG()))
            try await you("README 的截图也交给你，换成 Swift 版的样子，参考这张\n" + shot)
            _ = try await store.addCueMessage(.cue, text: "README 的截图换好了，浅色深色各一张。", task: panel?.id)
            _ = try await store.addCueMessage(
                .cue, text: """
                    预发部署好了，截图在这里。重连用例都过了：

                    ```
                    $ swift test --filter Reconnect
                    ✔ 重连后保留首次加入时间 (0.21s)
                    ✔ 6 人同时重连顺序不变 (0.48s)
                    ✔ 断线超过 5 分钟按新人排 (0.12s)
                    ✔ 主持人重连仍在第一位 (0.09s)
                    Executed 4 tests, with 0 failures
                    ```

                    看着没问题就**收下**，我把这件事关掉。
                    """, choices: ["收下", "再改改", "先别部署"], task: order?.id)
            for (text, pinned) in [("部署前先在测试群说一声", true), ("回复要短，先说结论", true), ("圆桌的预发环境是 staging-2", false), ("周五不发版", false)] {
                _ = try await store.noteCueLine(text, source: pinned ? .you : .cue, pinned: pinned)
            }
            let forgotten = try await store.noteCueLine("旧的计费脚本还在用", source: .cue)
            try await store.forgetCueLine(forgotten.line.id)
            switch presence {
            case "thinking": try await you("顺便看看登录回调那个超时")
            case "asleep":
                // 两分钟前说的、一直没交出去
                _ = try await store.addCueMessage(.you, text: "顺便看看登录回调那个超时")
            default: break
            }
        } catch {
            fatalError("Cue 演示数据没写成：\(error)")
        }
    }

    /// 部署那一步（deploy 会话）发来一张预发的截图：卡片与"等你"上的证据。
    private static func seedEvidence(_ store: CueStore) async {
        let file = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-staging.png")
        try? swatchPNG().write(to: file)
        _ = try? await store.addPreview(fileAt: file, title: "预发上的发言顺序", sessionID: "deploy")
    }

    /// 一张像截图的演示图：浅底上一列名单。
    private static func swatchPNG() -> Data {
        let view = VStack(alignment: .leading, spacing: 10) {
            Text("发言顺序").font(.system(size: 22, weight: .bold))
            ForEach(["小林", "阿杰", "Mia", "老王", "Sora", "Kai"], id: \.self) { name in
                HStack { Circle().fill(.indigo.opacity(0.7)).frame(width: 18); Text(name) }
            }
        }
        .padding(24).frame(width: 300, height: 360, alignment: .topLeading).background(Color(red: 0.95, green: 0.96, blue: 1))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage.map { DemoLibrary.encode($0) } ?? Data()
    }
}
#endif
