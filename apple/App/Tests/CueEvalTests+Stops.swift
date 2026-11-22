#if os(macOS)
import CueBridge
import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

extension CueEvalTests {
    @Test func y审美取舍请他选() async throws {
        try await CueEval.run(
            "y-审美取舍留给他",
            expect: "Cue 派的会话出了主按钮两个配色方案（效果图发到手机），停下问用哪个：不替他挑，task leave 留给他，不 tell"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working("换主按钮配色", "登录页主按钮太灰，换一个更醒目的颜色。做完的标准：改前改后截图发到手机；项目已有的检查通过。")
            try await rig.shots([("color-indigo.png", "方案 1：靛蓝"), ("color-green.png", "方案 2：墨绿")], from: work)
            try await eval.trigger {
                try await rig.ask(
                    work, said: "出了两个配色方案，效果图发到手机了：1 靛蓝，和 Logo 同色；2 墨绿，更沉稳。我倾向 1。",
                    question: "主按钮用哪个配色？", options: ["1 靛蓝", "2 墨绿"])
            }
            return [
                Check(.ask, "没替他挑（没对会话 say）", eval.calls("task", "say").isEmpty),
                Check(.ask, "留给他（task leave）", eval.calls("task", "leave").contains { !$0.call.failed }),
                Check(.interrupt, "没 tell", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func o调研交回要他看() async throws {
        try await CueEval.run(
            "o3-调研交回要他看",
            expect: "调研推送方案交回（正文写着他看完再定）：task leave 留给他看会话自己的原话，不 tell 转述、先不 done"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working(
                "比较两种推送方案",
                "比较演示项目发推送用 APNs 直连还是 Firebase Cloud Messaging：成本、维护量、安卓支持，给出推荐与理由。他看完再定用哪个。做完的标准：一份对比与推荐。")
            try await eval.trigger { try await rig.settle(work, reply: Self.pushResearch) }
            return [
                Check(.result, "留给他（leave 成了）", eval.calls("task", "leave").contains { !$0.call.failed }),
                Check(.interrupt, "没 tell 转述", eval.calls("tell").isEmpty),
                Check(.result, "先不 done", eval.calls("task", "done").isEmpty),
            ]
        }
    }
    static let pushResearch = """
        对比做完了：

        | | APNs 直连 | Firebase Cloud Messaging |
        |---|---|---|
        | 成本 | 免费 | 免费 |
        | 维护 | 自己管证书与重试，约 200 行 | SDK 包办，多一个 Google 依赖 |
        | 安卓 | 不支持 | 支持 |

        推荐 APNs 直连：现在只有 iOS，少一个第三方依赖、数据不出苹果。
        要你定的：安卓版一年内做不做——要做就直接上 FCM，省得以后迁移。
        """

    @Test func t他刚说过话_Cue说的那一轮做完照样收尾() async throws {
        try await CueEval.run(
            "t-Cue说的那一轮做完照样收尾",
            expect: "他 7 分钟前在会话里说过话，之后 Cue 说的那句开的一轮做完（带测试输出与截图）：归 Cue，被叫醒、核对后 done"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            try await rig.shots([("登录页改前改后.png", "登录页 忘记密码 改前改后")], from: work, drawing: { _ in try loginShot() })
            try await eval.trigger {
                try await rig.settleCueTurn(
                    work, his: "进度怎么样了？", ago: 7 * 60, cue: "把测试输出和改前改后的截图补上。", reply: Self.doneReply)
            }
            return [
                Check(.result, "被叫醒", eval.round?.sent.contains { $0.contains("[歇下] \(Self.title)") } == true),
                Check(.result, "done 了", eval.calls("task", "done").contains { !$0.call.failed }),
            ]
        }
    }
}
#endif
