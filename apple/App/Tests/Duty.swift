#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

@MainActor
final class Duty: EvalScript, Playable {
    static let expect = """
        值一段班（三十来次醒来）：中后段记得他口头交代的（这件做完后升版本号记 CHANGELOG、这周不跑 e2e）、早先会话查清的事实（发信走 Postmark）、\
        他否掉的方案（设置页不分标签页）；换新前后在做的事不重建、不重复说；\
        换新之后答得出他顺口说的行程、已完成的调研里顺带的细节（退信里邮箱不存在的 13 封），证书查完时照他要的说是哪家签发的；\
        换新前埋下、换新后考的：依赖清单建议 Node 升到几、设置页那版没改成立刻存的两项、忘记密码做完才派删 SendGrid、挂件不换成它否掉的 B、\
        逐页查死链接着下一页不重查
        """

    /// 换新线：场景前段就跨过，后段还能再跨一次
    static let renewAt = 42_000
    /// 提示缓存的时长缩短：他走开（`away`）比它长，回来就是冷换新；剧本平常两步之间远比它短
    static let cacheLifetime = Duration.seconds(30)
    static let away = Duration.seconds(45)

    func script() async throws -> [Check] {
        let site = try await rig.store.createProject(name: "官网", color: "green")
        let siteFolder = rig.app.directory.appending(path: "site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: siteFolder, withIntermediateDirectories: true)
        try await rig.store.setDirectory(siteFolder.path, for: site.id)

        // 前段：派活、口头交代、早先的事实、他否掉的方案；长回复与长消息把上下文撑过换新线
        let reset = try await say("他：登录页加忘记密码", CueEvalTests.request)
        let login = try await adopt(/忘记密码|重置密码/, after: reset, title: "登录页加忘记密码", in: "演示")
        try await say("他：做完后升版本号（口头、不记规矩）", "对了，忘记密码那件做完以后，让它顺手把演示项目的版本号从 2.3.0 升到 2.3.1，CHANGELOG 里记一笔。就这一次，不用记成规矩。")
        try await say("他：贴站会纪要（长）", LongScript.standup)
        try await say("他：顺口说行程（与任务无关）", "对了，我下周三下午 3 点的飞机去成都，周四晚上回来。")
        let mailAsk = try await say("他：查邮件服务", "演示项目现在发邮件用的是哪家服务、这个月额度还剩多少？找个会话查清楚。")
        let mail = try await adopt(/邮件|发信|额度/, after: mailAsk, title: "查清邮件服务与额度", in: "演示")
        try await event("忘记密码：问令牌存哪", on: login) {
            try await login.ask(
                said: "开始做重置令牌的存储。项目里 Postgres 和 Redis 都在用。",
                question: "重置令牌存哪里？\nA. 新建 password_resets 表（存令牌哈希、过期时间、是否已用）\nB. 存进 Redis，TTL 30 分钟，用过即删",
                options: ["A", "B"], rig: rig)
        }
        try await event("邮件服务：交回调研（长）", on: mail) { try await mail.settle(LongScript.mailReport, rig: rig) }
        let sendgrid = try await say("他：SendGrid 等忘记密码做完再删（托付）", "邮件那件看到了。SendGrid 那套旧配置要删，但等忘记密码那件做完再派会话去删——它现在也在动发信代码，两边别撞。你记着这事，到时候自己派，不用再问我。")
        let depsAsk = try await say("他：出依赖升级清单", "演示项目的依赖好久没升了，让会话出一份升级清单：哪些该升、风险多大。先别动手升。")
        let deps = try await adopt(/依赖|升级/, after: depsAsk, title: "出依赖升级清单", in: "演示")
        let depsListed = try await event("依赖：交回清单（长）", on: deps) { try await deps.settle(LongScript.depsReport, rig: rig) }
        let linksAsk = try await say("他：官网逐页查死链（多步）", "官网 4 个页面逐页查一下死链：首页、价格、博客、文档。一页一页来，每页查完先把死链数告诉我，再让它查下一页，别一次全派出去。")
        let links = try await adopt(/死链/, after: linksAsk, title: "官网逐页查死链", in: "官网")
        try await say("他：设置页重新设计（带反馈，长）", "演示项目的设置页太乱了，重新设计一下。下面是客服整理的用户反馈，转给会话参考：\n\n" + LongScript.feedback)
        let go = try await say("他：开工、不要标签页", "可以，按你说的开工。别做成分标签页那种，我不喜欢点来点去，就一页长列表、分组加小标题。")
        let settings = try await adopt(/设置/, after: go, title: "重新设计设置页", in: "演示")
        try await say("他：这周不跑 e2e（口头）", "这周 e2e 环境坏了，这周派出去的活都别跑 e2e，单元测试和 lint 过了就行。")
        let page1 = try await event("死链：首页查完", on: links) { try await links.settle(LongScript.linksHome, rig: rig) }
        try await event("忘记密码：API 500", on: login) {
            try await login.fail(#"500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#, rig: rig)
        }
        try await event("设置页：交回分组清单（长）", on: settings) { try await settings.settle(LongScript.settingsInventory, rig: rig) }
        let tier1 = try await say("他：依赖先升第一档", "依赖那件先把第一档升了，别的等等。")
        let upgrade = try await continuing(deps, /依赖|升级|第一档/, after: tier1)
        try await event("依赖：第一档升完（长）", on: upgrade) { try await upgrade.settle(LongScript.depsTier1, rig: rig) }
        let tsAsk = try await say("他：问 TS 那 14 处", "依赖清单里说 TypeScript 升级会报 14 处错，让它在临时分支上试一下，列出具体是哪些，先别修。")
        let trial = try await continuing(upgrade, /TypeScript|TS|报错/, after: tsAsk)
        try await event("依赖：列出 14 处报错（长）", on: trial) { try await trial.settle(LongScript.tsErrors, rig: rig) }
        let speed = try await say("他：官网 Lighthouse 掉分", "官网首页的 Lighthouse 性能分掉到 60 多了，查一下原因修掉。")
        let website = try await adopt(/Lighthouse|性能|首页/, after: speed, title: "修回官网首页性能分", in: "官网")
        let certAsk = try await say("他：查官网证书到期", "官网的 SSL 证书什么时候到期？找个会话查一下。")
        let cert = try await adopt(/证书|SSL/, after: certAsk, title: "查官网证书到期", in: "官网")
        try await say("他：证书查完告诉他签发方", "证书那件查完的时候顺便告诉我是哪家签发的，我要跟采购对一下账。")
        try await event("官网：交回分析（长）", on: website) { try await website.settle(LongScript.lighthouseAnalysis, rig: rig) }
        let widget = try await event("官网：问挂件怎么改（它来判断）", on: website) {
            try await website.ask(said: "开始按 1 → 2 → 3 改了，Hero 图已经转好。客服挂件有两种改法，想先跟你确认。", question: LongScript.widgetQuestion, options: ["A", "B"], rig: rig)
        }
        try await say("他：转来安全扫描报告（长）", LongScript.securityScan)
        try await event("忘记密码：后端做完（长）", on: login) { try await login.settle(LongScript.backendDone, rig: rig) }
        let page2 = try await event("死链：价格查完", on: links) { try await links.settle(LongScript.linksPricing, rig: rig) }
        let node = try await say("他：问依赖清单里 Node 的事", "依赖清单里顺带提了 Node 的事：Node 20 是什么时候停止维护的？建议升到几？")
        let progress = try await say("他：问登录页进展", "登录页那件做到哪了？")
        let layout = try await event("设置页：布局改完一版（长）", on: settings) { try await settings.settle(LongScript.layoutDone, rig: rig) }
        try await event("忘记密码：前端做了一半（长）", on: login) { try await login.settle(LongScript.frontendHalf, rig: rig) }

        // 中后段：判定点（放在换新线之后）
        let readmeAsk = try await say("他：README 截图重截", "演示项目 README 里的截图过时了，现在就让会话按现在的界面重截一遍换上；登录页和设置页改完后的样子以后再补。")
        let readme = try await adopt(/README/, after: readmeAsk, title: "重截 README 截图", in: "演示")
        try await event("README：问截图放哪", on: readme) {
            try await readme.ask(
                said: "README 用到的 9 张截图里，除了登录、设置两张先不换，其余 7 张都按现在的界面重截好了。旧图在 docs/images/ 和 assets/readme/ 两处都有：README 引用的是 docs/images/，assets/readme/ 里是没人引用的旧副本。",
                question: "新截图放哪？", options: ["docs/images/", "assets/readme/"], rig: rig)
        }
        let digestAsk = try await say("他：加每周周报邮件", "演示项目再加一个：每周一早上 9 点给上周活跃过的用户发一封周报邮件，列出他看板上上周新建、完成的任务数和最忙的一天。")
        let digest = try await adopt(/周报/, after: digestAsk, title: "加每周周报邮件", in: "演示")
        let readmeStatus = try await say("他：问 README 那件", "README 那件开工了吗？做到哪了？")
        let provider = try await event("周报邮件：问走哪家发信", on: digest) {
            try await digest.ask(
                said: "周报邮件的模板写好了（沿用注册验证邮件的样式），统计查询和每周一 9 点的定时任务也接好了。",
                question: "项目里同时有 SendGrid 和 Postmark 两套发信配置（config/mail.sendgrid.ts、config/mail.postmark.ts），周报邮件走哪个？",
                options: ["SendGrid", "Postmark"], rig: rig)
        }
        let tabs = try await event("设置页：问要不要拆标签页", on: settings) {
            try await settings.ask(
                said: "分组的长列表在手机上有 3 屏半长，\"高级\"组在最底下要滑一阵才到。",
                question: "设置项太多、页面太长，要不要拆成「通用 / 账号 / 通知」三个标签页？", options: ["拆成标签页", "保持一页长列表"], rig: rig)
        }

        // 他走开一阵：回来时缓存已过期，冷换新
        try await Task.sleep(for: Self.away)
        let page3 = try await event("死链：博客查完（冷）", on: links) { try await links.settle(LongScript.linksBlog, rig: rig) }
        let widgetAgain = try await event("官网：问要不要换成 B", on: website) {
            try await website.ask(
                said: "挂件按 A 改完了，但占位按钮在 Safari 上偶尔要点两下才打开挂件，在查原因。",
                question: "要不要干脆换成 B（脚本 async 照常加载），省得折腾占位按钮？", options: ["换成 B", "保持 A，接着修占位按钮"], rig: rig)
        }
        let instant = try await say("他：问设置页哪两项没改成立刻存", "设置页那一版里，原来要点保存的那些项，有两项没改成立刻存，是哪两项？为什么？")
        let e2e = try await event("官网：问跑不跑 e2e", on: website) {
            try await website.ask(
                said: "首页改好了：hero 图换成 AVIF 并按屏宽出图，字体改成 font-display: swap 并预加载，客服挂件改成点了才加载。本地 Lighthouse 移动端性能 63 → 92，单元测试 31 个全过，lint 干净。",
                question: "要不要再跑一遍 e2e 回归（Playwright，约 25 分钟）再交？", options: ["跑 e2e 回归", "只跑单元测试就交"], rig: rig)
        }
        let trip = try await say("他：问行程", "我去成都是哪天来着？几点的飞机？")
        let bounce = try await say("他：问调研里的细节", "之前查邮件服务那件，退信里有几封是邮箱不存在的？")
        let certified = try await event("证书：查完交回", on: cert) { try await cert.settle(LongScript.sslReport, rig: rig) }
        try await event("README：做完交回", on: readme) {
            try await readme.deliver(pageShot("README 截图（新）", LongScript.readmeShots), title: "README 新截图", rig: rig)
            try await readme.settle(LongScript.readmeDone, rig: rig)
        }
        let finish = try await event("忘记密码：做完交回", on: login) {
            try await login.deliver(loginShot(), title: "登录页 忘记密码 改前改后", rig: rig)
            try await login.deliver(pageShot("/reset 设新密码", ["新密码  ••••••••", "确认新密码  ••••••••", "强度：较强", "[ 重置密码 ]"]), title: "设新密码页", rig: rig)
            try await login.deliver(pageShot("/reset 链接已失效", ["链接已失效", "重置链接 30 分钟内有效、只能用一次。", "[ 重新发送重置邮件 ]"]), title: "链接失效页", rig: rig)
            try await login.deliver(pageShot("MailHog：两封邮件并排", ["左：验证你的邮箱（注册验证邮件）", "右：重置你的密码（重置邮件）", "同一页眉、按钮样式与页脚"]), title: "重置邮件与注册验证邮件并排", rig: rig)
            try await login.settle(LongScript.loginDone, rig: rig)
        }
        // 它记得升版本号、没收尾：会话补上，让托付（忘记密码做完才删 SendGrid）有个兑现的时候
        let loginClosed = { (step: Step) in self.calls(step, "task", ["done"]).contains { !$0.call.failed && self.target($0.args) === login } }
        var closed = finish
        if !loginClosed(finish) {
            let bumped = try await event("忘记密码：补上版本号与 CHANGELOG", on: login) { try await login.settle(LongScript.bumpDone, rig: rig) }
            if loginClosed(bumped) { closed = bumped }
        }
        try await event("官网：做完交回", on: website) {
            try await website.deliver(pageShot("Lighthouse 移动端 · 首页", LongScript.lighthouseShot), title: "首页 Lighthouse 改前改后", rig: rig)
            try await website.settle(LongScript.lighthouseDone, rig: rig)
        }
        let wrap = try await say("他：问今天的事", "今天这些事现在都怎么样了？")

        var checks = try await judge(login: login, settings: settings, site: website, digest: digest, key: Points(
            go: go, progress: progress, readmeStatus: readmeStatus, provider: provider, tabs: tabs, e2e: e2e, trip: trip, bounce: bounce,
            finish: finish, certified: certified, wrap: wrap, cert: cert))
        checks += try await probes(Probes(
            depsListed: depsListed, node: node, layout: layout, instant: instant, sendgrid: sendgrid, finish: closed,
            widget: widget, widgetAgain: widgetAgain, page1: page1, page2: page2, page3: page3, links: links, site: website, loginTask: login.task.id))
        return checks
    }
}
#endif
