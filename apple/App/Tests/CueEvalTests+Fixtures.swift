#if os(macOS)
import CueAgent
import CueBridge
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

    static let sidebarReply = """
        侧栏收口做完了：Agent 区去掉，每个项目行末尾带在跑的会话数，状态标只在项目行上出一处。

        验证：
        ```
        $ apple/scripts/xc.sh check
        lint ✔  CuePadKit build ✔  iOS build ✔
        ```
        截图都发到手机了：一路的方案稿 A/B、中途两版，和最终版。
        """

    static func body(_ added: [(call: CueToolCall, args: [String: Any])]) -> String? { added.first { !$0.call.failed }?.args["body"] as? String }

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
