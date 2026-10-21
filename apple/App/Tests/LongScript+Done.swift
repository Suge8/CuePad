#if os(macOS)
import Foundation

extension LongScript {
    static let sslReport = """
        查清楚了：官网的证书 2027-01-14 到期，还有 86 天；证书挂在 CDN 上，平台会在到期前 30 天自动续期，不用手动操作。没有改任何配置。

        ```
        $ echo | openssl s_client -connect www.demo-site.com:443 -servername www.demo-site.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
        subject=CN=*.demo-site.com
        issuer=C=GB, O=Sectigo Limited, CN=Sectigo RSA Domain Validation Secure Server CA
        notBefore=Jan 14 00:00:00 2026 GMT
        notAfter=Jan 14 23:59:59 2027 GMT
        X509v3 Subject Alternative Name:
            DNS:*.demo-site.com, DNS:demo-site.com
        ```

        - 类型：DV 通配符证书，覆盖 demo-site.com 和所有子域名（www、blog、status）。
        - 签发：Sectigo（中间证书 Sectigo RSA Domain Validation Secure Server CA）。
        - 续期：CDN 控制台「SSL/TLS → 边缘证书」里开着自动续期，上次续期是 2026-01-14，续期记录里没有失败。
        - 其他：TLS 1.2 与 1.3 开着，1.0、1.1 已关；HSTS 一年、含子域名；OCSP stapling 正常。
        - 预发环境 staging.demo-site.com 用的是另一张 Let's Encrypt 证书，2026-12-02 到期，同样自动续期。
        """

    static let loginDone = """
        忘记密码做完了，前后端都好了，没有提交、没有推送。

        ## 对照要求

        | 要求 | 结果 |
        | --- | --- |
        | 登录页有入口，填邮箱发重置邮件 | 登录页「忘记密码？」→ /forgot → 发信，/reset?token=… 设新密码 |
        | 链接 30 分钟有效、只能用一次 | 过期或用过的链接打开 /reset 显示「链接已失效」，带「重新发送重置邮件」入口 |
        | 沿用注册验证邮件的模板 | 同一个 verify.mjml，只换文案；MailHog 里两封并排对比图已发到手机 |
        | 同一邮箱一分钟最多一次 | 后端 60 秒限一次；前端提交后按钮 60 秒倒计时，被限流时也照样显示同一句提示，不显示「请稍后再试」 |
        | 不泄露邮箱是否存在 | 注册过、没注册、被限流三种情况都显示「如果这个邮箱注册过，你会收到一封邮件」，状态码都是 202，响应时间补齐到 300 ms |

        ## 五种情况手动走了一遍（本地 + MailHog）

        1. 注册过的邮箱：收到邮件，点链接设新密码后能用新密码登录、旧密码失效。
        2. 没注册的邮箱：同一句提示，MailHog 里没有邮件。
        3. 过期链接：把 expires_at 改到 31 分钟前，打开显示「链接已失效」。
        4. 用过的链接：设完新密码再点一次，显示「链接已失效」。
        5. 一分钟内连点：按钮在倒计时，强行用 curl 再请求一次，后端返回 202 和同一句提示、不发第二封。

        ## 验证

        ```
        $ npm test
         PASS  tests/auth/reset-request.test.ts (6 tests)
         PASS  tests/auth/reset.test.ts (6 tests)
         PASS  tests/auth/login.test.ts (9 tests)
         PASS  tests/pages/ForgotPage.test.tsx (6 tests)
         PASS  tests/pages/ResetPage.test.tsx (8 tests)
         PASS  tests/pages/LoginPage.test.tsx (11 tests)
        Test Suites: 6 passed, 6 total
        Tests:       46 passed, 46 total
        $ npm run lint
        ✔ No problems
        $ git status --short
         M src/pages/LoginPage.tsx
         M src/server/routes/auth.ts
        ?? migrations/20261019_add_password_resets.sql
        ?? src/pages/ForgotPage.tsx
        ?? src/pages/ResetPage.tsx
        ?? src/server/auth/reset.ts
        ?? templates/mail/reset.mjml
        ?? tests/auth/reset-request.test.ts
        ?? tests/auth/reset.test.ts
        ?? tests/pages/ForgotPage.test.tsx
        ?? tests/pages/ResetPage.test.tsx
        ```

        截图发到手机了：登录页改前改后与填邮箱页、/reset 设新密码页、链接失效页、MailHog 里重置邮件与注册验证邮件并排。e2e 按你说的这周没跑。
        """

    static let readmeShots = [
        "01-首页.png  1280×800  现在的首页（新导航）", "03-看板.png  1280×800  三栏看板",
        "04-编辑器.png  1280×800  Markdown 编辑与预览", "06-通知.png  1280×800  通知中心",
        "07-手机首页.png  390×844", "08-手机看板.png  390×844", "09-深色.png  1280×800  深色模式",
    ]

    static let readmeDone = """
        README 的截图换好了。

        - 9 张里重截了 7 张（Mac 1280×800、手机 390×844 各按原来的尺寸），放在 docs/images/，文件名沿用原来的，README 里的引用不用改。
        - 02 登录、05 设置两张照你说的没换，等那两件改完再补。
        - 对照表：01 首页、03 看板、04 编辑器、06 通知、07 手机首页、08 手机看板、09 深色模式。
        - assets/readme/ 里没人引用的旧副本没动，删不删等你定。

        ```
        $ ls -la docs/images/
        -rw-r--r--  1 dev  staff  412330 Oct 20 16:02 01-首页.png
        -rw-r--r--  1 dev  staff  301877 Sep  3 11:20 02-登录.png
        -rw-r--r--  1 dev  staff  455902 Oct 20 16:03 03-看板.png
        -rw-r--r--  1 dev  staff  377451 Oct 20 16:03 04-编辑器.png
        -rw-r--r--  1 dev  staff  336512 Sep  3 11:21 05-设置.png
        -rw-r--r--  1 dev  staff  289760 Oct 20 16:04 06-通知.png
        -rw-r--r--  1 dev  staff  201377 Oct 20 16:05 07-手机首页.png
        -rw-r--r--  1 dev  staff  219044 Oct 20 16:05 08-手机看板.png
        -rw-r--r--  1 dev  staff  433615 Oct 20 16:06 09-深色.png
        $ npx markdown-link-check README.md
        FILE: README.md
          [✓] docs/images/01-首页.png
          …（9 张都是 ✓）
          11 links checked.
        ```

        新截图的总览图发到手机了。
        """

    static let lighthouseShot = [
        "改前  Performance 63   LCP 5.8 s   TBT 620 ms   CLS 0.21", "改后  Performance 92   LCP 1.9 s   TBT 140 ms   CLS 0.02",
        "hero-2026.avif  640/1280/1920  共 312 KB", "inter-var  400/600  swap + preload", "chat widget  点了才加载",
    ]

    static let lighthouseDone = """
        官网首页的性能分修回来了：移动端 63 → 92。

        改动（都在官网仓库，没有推送）：
        1. Hero 图转 AVIF，640 / 1280 / 1920 三档写 srcset，加了 preload 与 fetchpriority="high"，2.3 MB → 三档合计 312 KB。
        2. 字体改成 preload + font-display: swap，只留 400 与 600 两个字重，用 size-adjust 对齐了回退字体。
        3. 客服挂件改成点了「联系我们」才加载，按钮位置先放同尺寸占位。

        验证：
        ```
        $ npx lighthouse http://localhost:4173 --preset=perf --form-factor=mobile（3 次取中位）
        Performance 92 | FCP 1.1 s | LCP 1.9 s | TBT 140 ms | CLS 0.02 | Speed Index 1.8 s
        $ npm test
        Tests: 31 passed, 31 total
        $ npm run lint
        ✔ No problems
        ```
        改动的文件（都没提交、没推送）：
        - index.html：首图加 preload 与 fetchpriority="high"，客服挂件的脚本从 <head> 里拿掉
        - src/styles/fonts.css：字体改成 preload + font-display: swap，只留 400 与 600，加 size-adjust
        - src/components/Hero.tsx：首图改成 <picture>，640 / 1280 / 1920 三档 srcset
        - src/components/ChatWidget.tsx：点了「联系我们」才加载挂件，先放同尺寸占位
        - public/images/hero-2026-640.avif、hero-2026-1280.avif、hero-2026-1920.avif：新增的三档首图（原来的 PNG 留着没删）
        ```
        $ git status --short
         M index.html
         M src/components/ChatWidget.tsx
         M src/components/Hero.tsx
         M src/styles/fonts.css
        ?? public/images/hero-2026-1280.avif
        ?? public/images/hero-2026-1920.avif
        ?? public/images/hero-2026-640.avif
        $ git diff --stat
         index.html                    |  9 ++++++---
         src/components/ChatWidget.tsx | 41 +++++++++++++++++++++++++++++------------
         src/components/Hero.tsx       | 18 ++++++++++++------
         src/styles/fonts.css          | 22 ++++++++++++----------
         4 files changed, 58 insertions(+), 32 deletions(-)
        ```
        改前改后的 Lighthouse 对比截图发到手机了。
        """
}
#endif
