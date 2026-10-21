#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

extension CueEvalTests {
    static let request = """
        给演示项目的登录页加一个「忘记密码」：点了之后让用户填邮箱，发一封重置密码的邮件。几条要求：重置链接 30 分钟内有效、只能用一次；\
        邮件沿用现在注册验证邮件的模板样式；同一个邮箱一分钟内最多发一次，防止被刷；不管邮箱存不存在都提示「如果这个邮箱注册过，你会收到一封邮件」，别泄露用户是否存在。
        """
    static let title = "登录页加忘记密码"
    static let body = """
        登录页加「忘记密码」入口：填邮箱后发重置密码邮件。
        要求：重置链接 30 分钟内有效、只能用一次；邮件沿用注册验证邮件的模板；同一邮箱 1 分钟内最多发一次；不论邮箱是否存在都提示「如果这个邮箱注册过，你会收到一封邮件」。
        做完的标准：跑过项目已有的测试与 lint 并贴出输出；改前改后的登录页截图发到手机。推送前先停下来问。
        """

    /// 卡上已经问着（同 Cue 按他的规矩把三个方案交上来的那张：推荐 1，点名每个方案一张图）；会话还在、等他定。
    static func proposalsAsked(_ eval: CueEval) async throws -> (Working, CueMessage) {
        let rig = eval.rig
        let work = try await rig.working("重做提问卡", "提问卡出三个视觉方案：决定单、对话里问、郑重放行。做完的标准：每个方案的效果图发到手机，他选定后再实现。")
        var shots: [CueShot] = []
        for (slug, title) in proposals {
            let preview = try #require(try await rig.shots([("\(slug)-iphone.png", title)], from: work).first).preview
            shots.append(CueShot(preview: preview.id, look: title.replacingOccurrences(of: "提问卡", with: "")))
        }
        let asking = try CueAsking(.rule, action: "按方案 1 决定单改提问卡", rule: "重做界面设计要先给几个方案让我选")
        let question = try await rig.store.addCueMessage(
            .cue, text: "三个提问卡方案做好了，我推荐 1 决定单：点一下就答完。", ask: asking, shots: shots, task: work.task.id)
        return (work, question)
    }

    /// 他交代过界面方案要在卡上选；会话交回三个提问卡方案与效果图（还夹着先前别的改动的截图），Cue 被会话歇下叫醒的那一轮跑完。
    static func proposalsDelivered(_ eval: CueEval) async throws -> Working {
        let rig = eval.rig
        try await eval.trigger { try await rig.say("以后重做界面设计，先给我几个方案，交回时在卡上让我选") }
        let work = try await rig.working("重做提问卡", "提问卡出三个视觉方案：决定单、对话里问、郑重放行。做完的标准：每个方案的效果图（手机浅色、深色、原样与 Mac）发到手机。")
        try await rig.shots([
            ("1-01-改前-长按菜单.png", "上一轮的改动：改前长按菜单"), ("1-02-改后-长按菜单.png", "上一轮的改动：改后长按菜单"),
            ("2-01-改前-设置.png", "上一轮的改动：改前设置"), ("2-02-改后-设置.png", "上一轮的改动：改后设置"),
        ], from: work)
        let looks = [("iphone", "手机浅色"), ("iphone-dark", "手机深色"), ("iphone-original", "现在的样子"), ("mac", "Mac")]
        for (slug, title) in proposals {
            try await rig.shots(looks.map { ("\(slug)-\($0.0).png", "\(title) · \($0.1)") }, from: work)
        }
        try await eval.trigger { try await rig.settle(work, reply: proposalReply) }
        return work
    }

    static let proposals = [
        (slug: "decision-sheet", title: "提问卡方案 1：决定单"), (slug: "in-thread", title: "提问卡方案 2：对话里问"),
        (slug: "slide-to-allow", title: "提问卡方案 3：郑重放行"),
    ]

    static let proposalReply = """
        三个提问卡方案做好了，效果图都发到手机了（每个方案手机浅色、深色、Mac 各一张，另附一张现在提问卡的原样作对比）：
        1. 决定单：大按钮"可以"占满一行，下面是"以后不用问"。点一下就答完，最清楚。
        2. 对话里问：卡片留在对话里，按钮贴在输入框上方，答完卡片原地变成回答。
        3. 郑重放行：滑过去才算同意，"以后不用问"是个开关，适合推送、删除这类收不回的事。
        我推荐 1：信息最集中、一步答完；3 的滑动在 Mac 上不顺手。
        """

    static let sidebarReply = """
        侧栏收口做完了：Agent 区去掉，每个项目行末尾带在跑的会话数，状态标只在项目行上出一处。

        验证：
        ```
        $ apple/scripts/xc.sh check
        lint ✔  CuePadKit build ✔  iOS build ✔
        ```
        截图都发到手机了：一路的方案稿 A/B、中途两版，和最终版浅色、深色各一张。
        """

    static let doneReply = """
        忘记密码做好了。

        改动：
        - 登录页加「忘记密码？」链接，进到填邮箱的页面
        - POST /api/password/reset-request 发重置邮件（沿用注册验证邮件模板），令牌 30 分钟过期、用过即失效；同一邮箱 60 秒内只发一次（第二次返回 429）
        - 不论邮箱是否存在都提示「如果这个邮箱注册过，你会收到一封邮件」

        验证：
        ```
        $ npm test
         PASS  tests/auth/reset-password.test.ts (14 tests)
         PASS  tests/auth/login.test.ts (9 tests)
        Tests: 23 passed, 23 total
        $ npm run lint
        ✔ No problems
        ```
        手动走了一遍：注册过的邮箱提交后 MailHog 收到邮件，点链接设新密码后能用新密码登录，旧链接再点提示「链接已失效」；没注册的邮箱提示同一句话、不发邮件；60 秒内再点提示「请稍后再试」。

        改前改后的截图发到手机了。
        """
}
#endif
