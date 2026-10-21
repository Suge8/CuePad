#if os(macOS)
import AppKit
import CuePi
import CueStore
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 长程剧本里会话的长回复与他贴来的长文：撑大 Cue 的上下文（peek 给最新回答全文），也藏着后面要用的事实。
enum LongScript {
    static let mailReport = """
        查清楚了。结论：演示项目线上发信走的是 Postmark；SendGrid 那套是 2024 年迁移前留下的旧配置，已经不用了。这个月额度还剩 6,288 封，照现在的量月底前够用。

        ## 1. 用的是哪家

        - 发信入口在 src/mail/index.ts 的 `createTransport()`：读环境变量 `MAIL_PROVIDER` 选实现，`postmark` 走 config/mail.postmark.ts，`sendgrid` 走 config/mail.sendgrid.ts。
        - 生产环境（.env.production 与部署平台的环境变量）里是 `MAIL_PROVIDER=postmark`；预发环境也是 postmark；本地开发默认也是 postmark，只是 token 指向 Postmark 的沙盒 Server（demo-dev），邮件不会真发出去，在 Postmark 控制台的 Activity 里能看到。
        - config/mail.sendgrid.ts 现在只被 scripts/legacy-import.ts 引用，那个脚本最后一次改动是 2024-06-12（迁移到 Postmark 的那次提交 7c41e0a），之后没人跑过；SendGrid 的 API key 在 2024-07 已经吊销（SendGrid 控制台显示 revoked），就算有人把 MAIL_PROVIDER 改回 sendgrid 也发不出去，启动时会报 401。
        - 所以：新写的发信代码都应该走 Postmark；SendGrid 配置可以找时间删掉，但删除前要先问你。

        ```
        $ rg -n "MAIL_PROVIDER" --glob '!node_modules'
        src/mail/index.ts:14:  const provider = process.env.MAIL_PROVIDER ?? "postmark";
        .env.example:9:MAIL_PROVIDER=postmark
        deploy/production.env.tpl:22:MAIL_PROVIDER=postmark
        deploy/staging.env.tpl:22:MAIL_PROVIDER=postmark
        $ rg -ln "mail.sendgrid" --glob '!node_modules'
        scripts/legacy-import.ts
        $ git log -1 --format='%h %ad %s' --date=short -- scripts/legacy-import.ts
        7c41e0a 2024-06-12 迁移发信到 Postmark，SendGrid 只留给旧数据导入
        $ rg -n "sendMail\\(|transport\\.send\\(" src --glob '!**/*.test.ts' | wc -l
              17
        ```

        17 处调用发信的地方都经 `createTransport()`，没有绕过它直接调 SendGrid 或 Postmark SDK 的。

        ## 2. 账号与配置

        - Postmark 账号 ops@demo.dev，Server 名 demo-prod，发信域名 mail.demo.dev；DKIM 与 Return-Path 都已验证，SPF 记录里包含 spf.mtasv.net。
        - API token 在 1Password 的「demo-mail / Postmark server token」条目；CI 里对应的 secret 是 `POSTMARK_TOKEN`，部署平台里同名。
        - 消息流：事务邮件走 `outbound`，营销邮件走 `broadcast`（目前没在用）。注册验证邮件、重置密码邮件都属于事务邮件；以后要发周报、活动这类批量邮件，按 Postmark 的规矩要走 `broadcast` 流，不能混进 `outbound`，否则会影响事务邮件的送达率。
        - 模板：现有的邮件模板都在仓库里（templates/mail/*.mjml，构建时编译成 HTML），没有用 Postmark 自带的模板功能。

        ## 3. 额度

        - 套餐 Basic：每月 10,000 封，每月 1 号重置。
        - 10 月到今天已发 3,712 封，剩 6,288 封；最近 7 天日均约 180 封，照这个量到月底大约再发 2,000 封，够用。
        - 超出后要么限流，要么按 $1.30 / 千封计超额费：账单页的 overage 现在是关着的。按现在的量不会碰到，先记一笔。

        ```
        $ curl -s -H "X-Postmark-Server-Token: $POSTMARK_TOKEN" "https://api.postmarkapp.com/stats/outbound?fromdate=2026-10-01&todate=2026-10-20"
        {"Sent":3712,"Bounced":15,"SMTPApiErrors":0,"BounceRate":0.40,"SpamComplaints":0,"SpamComplaintsRate":0.00,"Tracked":0,"Opens":0}
        $ curl -s -H "X-Postmark-Server-Token: $POSTMARK_TOKEN" "https://api.postmarkapp.com/stats/outbound/sends?fromdate=2026-10-13&todate=2026-10-19"
        {"Days":[{"Date":"2026-10-13","Sent":172},{"Date":"2026-10-14","Sent":181},{"Date":"2026-10-15","Sent":190},{"Date":"2026-10-16","Sent":176},{"Date":"2026-10-17","Sent":185},{"Date":"2026-10-18","Sent":169},{"Date":"2026-10-19","Sent":187}],"Sent":1260}
        ```

        ## 4. 健康度

        - 退信率 0.40%、投诉率 0%，都在 Postmark 建议的范围内（退信 < 10%、投诉 < 0.1%）。
        - 15 封退信里 13 封是 hard bounce（邮箱不存在），都来自注册时手误的邮箱，已自动进 suppression 列表；另外 2 封是对方邮箱满了的 soft bounce。
        - 平均投递时间 1.8 秒，最近 30 天没有出现过发信接口报错。

        ## 5. 顺带发现的

        1. 新的发信代码只用 Postmark，别再碰 config/mail.sendgrid.ts。
        2. SendGrid 的旧配置与 scripts/legacy-import.ts 可以删，删之前先问你。
        3. .env.example 里还留着 SENDGRID_API_KEY 这一行，新同事照着配会以为两家都要配，建议跟着上面那条一起清掉。
        """

    static let settingsInventory = """
        先把现在的设置页摸了一遍，把分组结构定下来了，还没动界面。

        ## 现状

        设置页（src/pages/settings/SettingsPage.tsx，1,240 行）现在 46 项平铺在一个长表单里，顺序是按加功能的先后堆的：账号相关的散在第 3、17、29、40 项，通知开关散在 8 处，几个开发者选项夹在外观设置中间。搜索框只按标签全文匹配，搜"邮件"会同时出来通知邮件、登录邮箱、导出到邮箱三种不相干的东西。每一项的保存是各写各的：有 31 项改了立刻存，15 项要点页面最底下的"保存"，而那个按钮在手机上要滑 5 屏才看得到，用户反馈里有 23 条说"改了设置没生效"，基本都是这个原因。

        ## 46 项的归类

        | 组 | 项数 | 内容 |
        | --- | --- | --- |
        | 账号 | 8 | 头像、昵称、登录邮箱、手机号、修改密码、两步验证、已登录设备、注销账号 |
        | 通知 | 9 | 邮件通知总开关、评论、提及、关注、周报、产品更新、推送总开关、推送免打扰时段、声音 |
        | 外观 | 6 | 主题（浅/深/跟随系统）、强调色、字号、紧凑模式、侧栏位置、动画 |
        | 编辑器 | 7 | 默认格式、自动保存间隔、拼写检查、Markdown 快捷键、代码块主题、制表符宽度、自动补全 |
        | 隐私 | 6 | 资料可见范围、在线状态、已读回执、搜索引擎收录、数据收集、屏蔽列表 |
        | 数据 | 5 | 导出全部数据、导出到邮箱、导入、存储用量、清除缓存 |
        | 高级 | 5 | 开发者模式、API 令牌、Webhook、实验功能、重置所有设置 |

        ## 打算怎么排

        - 一页长列表，7 组按上面的顺序排，每组一个小标题，组内按使用频率排（埋点数据在 analytics/settings-usage.csv，近 30 天）。
        - 顶部的搜索改成按组过滤：搜到的项连同它的组标题一起显示；搜不到时提示"没有这一项，可能在账号中心里"，因为有 4 项（实名认证、发票、团队成员、付费方案）其实在账号中心，不在设置页。
        - 保存方式统一成改了立刻存，每项右边出一个小对勾表示存好了；底部的"保存"按钮去掉。要二次确认的只有危险操作。
        - 危险操作（注销账号、重置所有设置）挪到各组最底下，红字，点了要二次确认。
        - 改动只动布局与顺序，不改每一项的行为与存储的键名，老用户的设置不受影响。

        ## 使用频率（近 30 天，前 15）

        ```
        theme                 18,204
        notifications.email   11,930
        editor.autosave        9,415
        avatar                 7,866
        password               6,102
        font_size              5,877
        push.quiet_hours       4,310
        two_factor             3,955
        export.all             2,201
        devices                1,987
        editor.spellcheck      1,640
        accent_color           1,512
        privacy.profile        1,208
        push.enabled           1,155
        compact_mode             988
        ```

        后 10 项近 30 天加起来不到 200 次（Webhook、制表符宽度、侧栏位置、实验功能等），按组排进去即可，不单独处理。

        ## 风险

        - 有 3 个第三方插件通过 `#settings-editor-autosave` 这类锚点直接跳到某一项，改布局要保留这些锚点 id，我会在组件里照旧输出。
        - 设置页的 e2e 用例（tests/e2e/settings.spec.ts）按"第 n 个输入框"定位元素，改顺序后会全挂；这次按你说的不跑 e2e，但用例要顺手改成按标签定位，不然下周环境好了一跑就红。

        接下来改 SettingsPage 的布局：先拆出 SettingsGroup 组件，再把 46 项按上面的表挪进去。
        """

    static let lighthouseAnalysis = """
        查到原因了：性能分从 9 月底的 91 掉到现在的 63（移动端），主要是三处，都是最近两周上线的改动带进来的。

        ## Lighthouse（移动端，首页，本地 3 次取中位）

        ```
        Performance        63
        First Contentful Paint   2.9 s
        Largest Contentful Paint 5.8 s
        Total Blocking Time      620 ms
        Cumulative Layout Shift  0.21
        Speed Index              4.7 s
        ```

        桌面端是 88，掉得没那么多，所以之前没人注意到。线上 CrUX 数据（近 28 天真实用户）也印证了：移动端 LCP 的 75 分位从 2.1 s 涨到了 4.6 s，从"良好"掉进了"差"。

        ## 原因

        1. **Hero 图**（LCP 元素）：10 月 8 日换的新首图是 2.3 MB 的 PNG（3840×2160），所有屏宽都下这一张，没有 srcset，也没有 preload。LCP 5.8 s 里有 4.1 s 在等它。图本身是一张有大片纯色背景的插画，转成 AVIF 体积能降到原来的十分之一以下，肉眼看不出差别。
        2. **字体**：10 月 12 日引入的 Inter 可变字体（3 个字重，共 780 KB）用 @import 写在 CSS 里，阻塞渲染；`font-display` 没写，默认是 block，首屏文字要等字体到了才画，FCP 被拖到 2.9 s。字体换上时行高不同，引起 0.12 的 CLS。页面实际只用到了 400 和 600 两个字重，700 那份是白下的。
        3. **客服挂件**：10 月 15 日加的第三方客服挂件（widget.chatvendor.io）在 `<head>` 里同步加载 610 KB 的脚本，主线程长任务累计 540 ms，是 TBT 的大头；挂件的悬浮按钮晚出现，又贡献了 0.09 的 CLS。挂件的使用率很低：近两周 41,000 次首页访问里只有 86 次点开过它。

        ```
        $ npx lighthouse http://localhost:4173 --preset=perf --form-factor=mobile --output=json | jq '.audits["largest-contentful-paint-element"].details.items[0].items[0].node.snippet'
        "<img src=\\"/images/hero-2026.png\\" class=\\"hero__image\\" alt=\\"\\">"
        $ ls -la public/images/hero-2026.png
        -rw-r--r--  1 dev  staff  2412876 Oct  8 10:21 public/images/hero-2026.png
        $ npx lighthouse ... | jq '.audits["render-blocking-resources"].details.items[] | {url, wastedMs}'
        {"url":"https://fonts.example-cdn.com/inter-var.css","wastedMs":1180}
        {"url":"https://widget.chatvendor.io/v3/loader.js","wastedMs":760}
        $ npx lighthouse ... | jq '.audits["bootup-time"].details.items[0:3][] | {url, scripting}'
        {"url":"https://widget.chatvendor.io/v3/loader.js","scripting":541.2}
        {"url":"http://localhost:4173/assets/index-8f2c1.js","scripting":212.7}
        {"url":"Unattributable","scripting":61.3}
        $ git log --since=2026-09-25 --format='%h %ad %s' --date=short -- public/images src/styles index.html
        b81d3e2 2026-10-15 首页接入客服挂件
        4a09c7f 2026-10-12 换成 Inter 可变字体
        e17f5aa 2026-10-08 更新首页首图
        ```

        ## 不是原因的（排除过）

        - 打包体积：主包 index-8f2c1.js 186 KB（gzip 后 61 KB），和 9 月底比只多了 3 KB，不是问题。
        - 服务器响应：TTFB 中位 180 ms，CDN 命中率 97%，和之前一样。
        - 第三方统计脚本：一直是 async 加载，长任务只有 30 ms 左右。

        ## 打算怎么改（按收益排）

        1. Hero 图转 AVIF，按 640 / 1280 / 1920 三档出图写 srcset，加 `fetchpriority="high"` 和 preload；预计 LCP 回到 2 s 以内。
        2. 字体改成 `<link rel="preload">` + `font-display: swap`，只留正文用的 400 与 600 两个字重，用 `size-adjust` 对齐回退字体的行高，消掉字体那份 CLS。
        3. 客服挂件改成点了"联系我们"才加载，按钮位置先用一个同尺寸的占位，消掉它那份 CLS 和长任务。

        三处都只动官网仓库，不涉及推送和发布；先按 1 → 2 → 3 的顺序改，改完再跑一遍 Lighthouse 对比。
        """
}
#endif
