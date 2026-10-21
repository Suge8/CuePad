#if os(macOS)
import Foundation

extension LongScript {
    static let layoutDone = """
        设置页的布局改完一版了：一页长列表、7 个分组，每组一个小标题，保存方式统一成改了立刻存。

        ## 改了什么

        - 拆出了 `SettingsGroup`（组标题 + 组内各项）和 `SettingsRow`（标签、说明、控件、存好了的小对勾）两个组件，SettingsPage.tsx 从 1,240 行降到 310 行。
        - 46 项按分组表挪进了 7 组：账号、通知、外观、编辑器、隐私、数据、高级；组内按近 30 天的使用频率排。
        - 保存：每项改了就存，存好后右边的对勾亮 1.5 秒；底部的"保存"按钮去掉了。原来要点保存的 15 项里，有 2 项（登录邮箱、手机号）改了要发验证码，这两项保留了"发送验证码"的确认步骤，没有改成立刻存。
        - 搜索：顶部的搜索按组过滤，搜到的项连同组标题一起显示；搜"邮件"现在分在通知、账号、数据三组里，一眼看得出是哪种邮件。
        - 危险操作：注销账号挪到账号组最底下、重置所有设置挪到高级组最底下，都是红字、点了二次确认。
        - 第三方插件用的锚点 id（`#settings-editor-autosave` 这类）原样保留，用旧链接跳进来能定位到对应的项，并且高亮 2 秒。
        - e2e 用例里按"第 n 个输入框"定位的地方都改成了按标签定位（没跑，这周不跑 e2e）。

        ## 验证

        ```
        $ npm test -- settings
         PASS  tests/settings/SettingsPage.test.tsx (18 tests)
         PASS  tests/settings/SettingsRow.test.tsx (7 tests)
         PASS  tests/settings/search.test.ts (6 tests)
        Tests: 31 passed, 31 total
        $ npm run lint
        ✔ No problems
        $ npm run typecheck
        ✔ tsc --noEmit: 0 errors
        ```

        单元测试里覆盖了：每一项的存储键名没变（对着改前导出的 46 个键逐一比对）、立刻存成功后对勾出现、存失败时控件回到原值并提示、旧锚点能定位。

        ## 还没做的

        - 改前改后的截图还没截：本地模拟器今天起不来，正在换 Xcode 版本，好了就截手机与桌面两种宽度发到手机。
        - 手机上整页现在大约 3 屏半长，"高级"组在最底下，要滑一阵才到；后面可能要考虑在顶部加个分组的跳转。

        接下来等模拟器好了就截图。
        """

    static let frontendHalf = """
        前端做了一半：登录页的入口和填邮箱的页面好了，设新密码的页面还在做。

        ## 已经好的

        - 登录页密码框下面加了「忘记密码？」链接，点了进 /forgot。
        - /forgot 页：一个邮箱输入框和「发送重置邮件」按钮；提交后不管结果如何都显示「如果这个邮箱注册过，你会收到一封邮件」，按钮变成 60 秒倒计时，倒计时期间不能再点（和后端的限流对齐，避免用户连点看到 429）。
        - 邮箱格式不对时在输入框下面就地提示，不发请求；网络出错时提示「网络不太好，稍后再试」，不显示后端的原始报错。
        - 文案都走了 i18n（zh-CN 与 en 两份），和登录页其余文案放在同一个命名空间。
        - 键盘：在邮箱框里回车就提交；Tab 顺序是输入框 → 按钮 → 返回登录。

        ## 还在做的

        - /reset?token=… 页：两个密码框（新密码、确认新密码）、密码强度提示、提交后跳回登录页并提示「密码已重置，请用新密码登录」。
        - 令牌过期或用过时（后端返回 410）显示「链接已失效」，并给一个「重新发送重置邮件」的入口。
        - 改前改后的截图和端到端走一遍，等 /reset 页做完一起做。

        ## 现在的测试

        ```
        $ npm test -- forgot
         PASS  tests/pages/ForgotPage.test.tsx
          ✓ 提交后显示同一句提示（邮箱存在） (38 ms)
          ✓ 提交后显示同一句提示（邮箱不存在） (21 ms)
          ✓ 提交后按钮进入 60 秒倒计时 (44 ms)
          ✓ 邮箱格式不对不发请求 (12 ms)
          ✓ 网络出错显示友好提示 (19 ms)
          ✓ 回车提交 (15 ms)
         PASS  tests/pages/LoginPage.test.tsx (11 tests)
        Tests: 17 passed, 17 total
        $ npm run lint
        ✔ No problems
        ```

        后端那 21 个测试也重跑了一遍，都还是绿的。接下来做 /reset 页。
        """

    static let bumpDone = """
        补上了：package.json 的版本号 2.3.0 → 2.3.1，CHANGELOG.md 加了一条。

        ```
        $ git diff --stat
         CHANGELOG.md | 6 ++++++
         package.json | 2 +-
         2 files changed, 7 insertions(+), 1 deletion(-)
        $ sed -n 1,8p CHANGELOG.md
        ## 2.3.1 - 2026-10-21
        ### 新增
        - 登录页「忘记密码」：邮件重置链接 30 分钟有效、只能用一次；同一邮箱一分钟最多发一次
        ```

        都只在本地，没有推送。
        """

    static let widgetQuestion = """
        客服挂件怎么改？
        A. 点了「联系我们」才加载脚本，先放一个同尺寸的占位按钮（多写约 40 行，CLS 与长任务都能消掉）
        B. 只把挂件脚本改成 async 照常加载（改一行；但悬浮按钮照样晚出现，CLS 的 0.09 消不掉，而且 async 后这个挂件偶尔会初始化两次，客服后台会收到重复会话）
        """

    static let linksHome = """
        首页查完了：3 个死链。
        - /about/team-2023 → 404（团队页去年改版后换成了 /about/team）
        - 页脚「合作伙伴」链到 partners.example-old.com，域名已过期
        - 首页博客卡片里的 /blog/launch-week → 404（那篇文章 9 月被删了）
        其余 41 个链接都正常（HEAD 请求 200，或 301 到正确的地址）。只查了首页，等你说查下一页。
        """

    static let linksPricing = """
        价格页查完了：2 个死链。
        - 「企业版」按钮链到 /pricing/enterprise → 404（企业版页面上个月并进了 /contact-sales）
        - 底部「旧版套餐说明」链到 /legacy-plans → 410
        其余 18 个链接正常。只查了价格页，等你说查下一页。
        """

    static let linksBlog = """
        博客页查完了：5 个死链，都是文章里引用的外站。
        - 《我们为什么换掉 Webpack》引用的 webpack-perf.example.dev/bench → 域名解析不到
        - 《首页提速 40%》引用的 web.dev/lcp-2022 → 404
        - 《远程协作这一年》里的两张 imgur 外链图 → 404
        - 《团队空间预告》链到 /spaces-beta → 404（内测页还没上线）
        其余 63 个链接正常。只查了博客页，等你说查下一页。
        """

    static let tsErrors = """
        TypeScript 5.6 报的 14 处新错误都列出来了（在一个临时分支上试的，没提交，主分支没动）。全是"可能为 undefined 却直接用了"这一类，都是真问题，不是误报。

        ## 按模块

        ### 认证（3 处）
        1. src/auth/session.ts:48 `user.profile.locale` —— profile 在注销流程里可能已经删掉，读 locale 会抛错。线上日志里 9 月有 12 次 "Cannot read properties of undefined (reading 'locale')"，就是这里。
        2. src/auth/tokens.ts:91 `payload.sub` —— 解析失败时 payload 是 undefined，现在靠外层 try/catch 兜住，报的错误信息不对（显示成"令牌过期"）。
        3. src/auth/oauth.ts:133 `account.provider` —— 第三方登录回调里，用户在授权页点了"取消"时 account 为空。

        ### 看板（5 处）
        4. src/board/columns.ts:27 `columns.find(...)!.cards` —— 非空断言；列被别人删了以后再拖卡片会崩。
        5. src/board/columns.ts:64 同上，排序时。
        6. src/board/drag.ts:112 `target.dataset.index` —— 拖到列表外时 target 是 document，没有 dataset。
        7. src/board/filters.ts:39 `filters.assignee.id` —— 筛选"未分配"时 assignee 是 null。
        8. src/board/stats.ts:18 `days[busiest].count` —— 一周都没有活动时 busiest 是 -1。周报邮件会用到这个统计，最好先修。

        ### 编辑器（3 处）
        9. src/editor/autosave.ts:55 `draft.updatedAt.getTime()` —— 新建的草稿还没存过时 updatedAt 为空。
        10. src/editor/paste.ts:22 `clipboard.files[0].type` —— 粘贴纯文本时 files 是空数组。
        11. src/editor/mentions.ts:80 `members.get(id).name` —— 被提及的人已经退出团队。

        ### 设置（2 处）
        12. src/pages/settings/useSetting.ts:31 `defaults[key]` 的返回值直接当字符串用，新增的键没有默认值时会存进 "undefined" 这个字符串。设置页重做正好会碰到这个文件。
        13. src/pages/settings/export.ts:14 `user.email.split('@')` —— 只用手机号注册的用户没有邮箱。

        ### 其他（1 处）
        14. src/integrations/webhook.ts:66 `res.headers['x-signature'].toString()` —— 对方不带签名头时抛错，Webhook 调用记录里显示"内部错误"。

        ## 修起来的工作量

        - 每处都是加判断或给默认值，改动都在 1–5 行；14 处加起来大约 60 行。
        - 第 1、8、12 处建议优先：1 有线上报错，8 会影响周报邮件的统计，12 会和设置页的重做撞在同一个文件。
        - 修完再升 TypeScript，就是一个只改 package.json 的小提交。

        ```
        $ npx tsc --noEmit -p tsconfig.json 2>&1 | tail -3
        src/integrations/webhook.ts(66,5): error TS18048: 'res.headers['x-signature']' is possibly 'undefined'.

        Found 14 errors in 11 files.
        ```

        没修，等你定要不要做第二档。
        """

    static let securityScan = """
        安全组刚发来的扫描报告，你对一下和依赖那件是不是一回事，不用转给会话。

        【安全组季度扫描 · 演示项目 · 2026-10-20】
        扫描范围：生产依赖（不含开发依赖）、容器镜像、公开端口、密钥泄露。

        一、依赖漏洞（4 项，均为本季度需清零的高危或中危）
        1. jsonwebtoken < 9.0.0：令牌校验时可被诱导使用不安全的算法。等级：高危。处置：升级到 9.x 并在校验时显式指定算法。
        2. axios < 1.7.4：服务端请求伪造。等级：高危。处置：升级到 1.7.4 以上；调用第三方时关闭自动跟随跳转。
        3. semver < 5.7.2：正则表达式拒绝服务。等级：高危。处置：升级引入它的直接依赖。
        4. express < 4.19.2：畸形地址导致的开放跳转。等级：中危。处置：升级到 4.19.2 以上。

        二、容器镜像（2 项）
        1. 基础镜像 node:20-bullseye 中的 openssl 有一个中危公告。处置：换成 node:22-bookworm-slim，镜像体积也能从 1.1 GB 降到 240 MB。
        2. 镜像里以 root 运行应用。处置：Dockerfile 加 USER node。等级：低危。

        三、公开端口（0 项）
        未发现除 443 以外的公开端口。

        四、密钥泄露（1 项）
        1. .env.example 中仍有 SENDGRID_API_KEY 字段（值为空），不是泄露，但容易让人误以为需要配置。等级：信息。处置：删除该字段。

        五、时间要求
        - 高危：本季度末（12/31）前清零。
        - 中危：下季度末前清零。
        - 低危与信息：自行安排。

        六、复查方式
        修复后在工单里回复提交号，安全组会在一周内复扫确认。
        """
}
#endif
