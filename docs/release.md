# 签名、发布与 CloudKit 结构

## 签名

本机构建走 ad-hoc 签名（`xc.sh` 覆盖工程默认的团队与身份，并换用不含 iCloud/推送的 macOS 权限文件）；签名事实源是 `App/Config/Signing.xcconfig`。发布与真机构建是手动签名：Xcode 的自动签名用 API 密钥时管不了 App Group 与 iCloud 容器，所以证书与描述文件由 `scripts/provision.py` 经 App Store Connect API 创建，工程里各 target 指定名称（只对 `iphoneos` 与 macOS 的 Release 生效，模拟器与日常构建不受影响）。

凭据文件 `~/.appstoreconnect/cuepad.env`（不入库）的字段：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_PATH`（API 密钥 `.p8` 的路径）、`CUEPAD_TEAM_ID`；`xc.sh release ios` 另需 `CUEPAD_TESTER_EMAIL`。Apple Distribution 证书的私钥放专用钥匙串 `~/.appstoreconnect/cuepad-signing.keychain-db`。缺凭据文件时 build/test/shot 照常，只有发布命令会报错；密钥内容不会打印。

权限：主 App 有 iCloud（`iCloud.com.sugeh.cuepad`）、推送（`$(APS_ENVIRONMENT)`：Debug development，Release production）与 App Group（iOS）；扩展只有 App Group；macOS 另有 Apple Events 自动化（终端跳转）。

只能在网页上做的一次性前置：App Group `group.com.sugeh.cuepad` 与 iCloud 容器的创建及挂到 App ID（主 App 与通知服务扩展 `com.sugeh.cuepad.notify` 都要挂）；Developer ID Application 证书（账号持有人创建，CSR 由 `provision.py devid-csr` 生成，`devid-import <.cer>` 导入）；App Store Connect 里的 App 记录。

## 命令

命令的步骤以 `xc.sh` 与 `scripts/` 下脚本的头注释为准，这里只列入口。发布命令只在没有未提交改动的检出里运行（否则拒绝），产物对应一个提交：共用的主检出常有并行中的改动，发布用单独的干净检出。

| 命令 | 作用 |
| --- | --- |
| `xc.sh provision` | 幂等：App ID 与能力、Apple Distribution 证书、iOS 与 macOS 描述文件 |
| `xc.sh release mac` | 归档（Developer ID）→ 公证 → 装订 → zip 与签名的 `appcast.xml` → 替换 GitHub Release 的资产 → 从公开地址回读校验；`--dry-run` 停在本地产物不上传 |
| `xc.sh release ios` | 归档 → 导出 IPA → 上传 TestFlight → 加入内部测试组 |
| `xc.sh device` | 登记连接的真机 → 开发构建 → 安装并启动 |
| `scripts/testflight.py builds` | 列出 TestFlight 构建与处理状态 |

## 版本号

发布时由同一个时间戳推出两个版本（`_signing.sh` 的 `release_versions`，mac 与 iOS 共用）：显示版本是日期（`2026.10.13`），构建号是分钟（`2610131639`）。TestFlight 与 Sparkle 按构建号比较新旧；同日多次发布显示版本相同，Sparkle 的更新提示会在后面补上构建号。工程里的 `MARKETING_VERSION` 只用于本机构建。

## 自动更新（macOS）

Sparkle 2（EdDSA 校验，只发完整包、不做增量），以官方二进制 xcframework 引入：`Vendor/Sparkle/Package.swift` 只有一个 `binaryTarget`（url + checksum，升级版本改这一处），不拉源码。更新源（`SUFeedURL`，即下面固定 Release 里的 `appcast.xml`）与公钥在 `App/Config/CuePad-macOS-Info.plist`；隔离模式（`CUEPAD_LIBRARY_DIR`）不启动更新器。

EdDSA 私钥在专用钥匙串（`cuepad-sparkle-ed25519`，不入库；`scripts/sparkle.sh key` 首次运行时生成并打印公钥）。

下载位置只有一处：GitHub 仓库 `Suge8/CuePad` 里一个固定的 Release（标签 `v0.1.0`，标题 "CuePad for Mac"）。发布不新建版本或标签，`release mac` 每次原地替换它的资产，都经 `releases/latest/download/<文件名>` 访问。资产固定是三个：

| 资产 | 用途 |
| --- | --- |
| `CuePad-mac-arm64.zip` | 官网下载按钮的固定地址 |
| `appcast.xml` | 更新源，只含最新这一版 |
| `CuePad-mac-arm64-<构建号>.zip` | 与官网包是同一个文件，appcast 的 enclosure 指向它 |

enclosure 带构建号，是因为 GitHub 不能一次替换多个资产：如果 enclosure 用固定名字，换包与换 appcast 之间会有一段旧签名配新包的窗口，落后的客户端更新时验签失败；第二次上传失败时这种不配套会一直留着。所以上传顺序是：带构建号的新包 → `appcast.xml` → 官网包 → 删上一版带构建号的包。线上的 appcast 任何时刻都指向一个存在且签名配套的包，中途失败也一样，重跑 `release mac` 即可补齐。

更新链只依赖这个 Release，不经过官网。`releases/latest/download/` 会 302 到 GitHub 的下载服务器，Sparkle 用系统默认的 URLSession 取 appcast 与安装包，跟随 HTTPS 重定向。

## App 图标

`App/Sources/AppIcon.icon` 是 Icon Composer 的分层图标（浅色/深色/着色三种外观），由 `scripts/make-icon.py` 从 `design/final/logo-final.png` 矢量化生成（依赖 Pillow 与 potrace）；换 logo 后重跑脚本即可。菜单栏模板图是 `Assets.xcassets/MenuBarIcon`。

## CloudKit 数据结构

`apple/CloudKit/cuepad.ckdb` 由同步记录映射推出：映射改了 `CloudKitSchemaTests` 会失败，在 `apple/CuePadKit/` 下用 `CUEPAD_REGENERATE_SCHEMA=1 swift test --filter regenerateSchemaFile` 重新生成，再导入开发环境。管理令牌存在钥匙串 `cuepad-cloudkit-management-token`，不入库、不打印：

```bash
export CLOUDKIT_MANAGEMENT_TOKEN=$(security find-generic-password -a cuepad -s cuepad-cloudkit-management-token -w)
C="--team-id SVPPQJM9JG --container-id iCloud.com.sugeh.cuepad --environment development"
xcrun cktool validate-schema $C --file apple/CloudKit/cuepad.ckdb
xcrun cktool import-schema $C --validate --file apple/CloudKit/cuepad.ckdb
xcrun cktool export-schema $C --output-file /tmp/dev.ckdb   # 回读：服务端把字段按字母序排列并补系统字段，逐类型核对字段与权限
```

生产环境只能在 CloudKit 控制台网页点「Deploy Schema Changes」部署开发环境的结构，所以映射再改时重复"生成 → 导入开发环境 → 控制台部署"。发布带新字段或新记录类型的版本前必须先部署：生产容器里写未部署的字段或类型会让整条记录保存失败，Agent 会话状态与预览就同步不上去。

生产环境的结构只能增不能删：已下线的记录类型与字段在生成器里（`CloudKitSchema.retiredTypes` / `retiredFields`）照原样声明，客户端不再读写。

订阅也是 schema 的一部分，但不在 `.ckdb` 里，cktool 看不到也导不出：生产环境拒绝客户端创建没部署过的查询订阅（CKErrorDomain 12，底层 BadSyntax 2006），区域与数据库订阅不受限；订阅类型按通知形状匹配（换成 alertBody 的变体会被拒）。所以改订阅的定义要先让开发环境签名的构建在开发容器里保存同样的订阅，再在控制台 Deploy Schema Changes——确认页的 Record Types、Indexes、Security Roles 都显示 0、也不单独列出订阅，但部署照样生效。

`piSessionStates.context`、`piSessionStates.commands`、`piMessages.tools` 与记录类型 `previews` 已于 10-09 在控制台部署到生产（部署时用 `cktool` 回读核对过）。`cards.archivedAt` 未核实：发布前用 `cktool export-schema` 回读生产环境核对，缺的先部署。管理令牌过期时，在钥匙串 `cuepad-cloudkit-management-token` 里更新。
