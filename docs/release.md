# 签名、发布与 CloudKit 结构

入口是 `xc.sh release mac|ios`、`xc.sh device`、`xc.sh provision`，每步做什么在 `apple/scripts/` 下各脚本的头注释里（`release-mac.sh`、`release-ios.sh`、`provision.py`、`testflight.py`、`sparkle.sh`、`ck-production.sh`）。对外发布只在用户明确要求时做：发出去的包会推给所有用户。发布只在干净检出运行，否则 `xc.sh` 拒绝。

## 发版核对

`release mac` 导出后、公证前由脚本核对，不过就停：门铃中转活着、签名完整、包里的正式版标记 `CuePadRelease` 是 YES（`Signing.xcconfig` 的 `CUEPAD_RELEASE`，只有发版脚本归档时设）、包里的命令行在空家目录下去找正式资料库 `CuePad/Library` 而不是开发库 `CuePad Dev`。少了标记，装上的正式版会开开发库，用户看到的是空库。只核对、不上传用 `xc.sh release mac --dry-run`（照样提交公证）。

## 签名

签名的做法与理由在 `App/Config/Signing.xcconfig` 与 `scripts/_signing.sh` 的头注释里（凭据文件的字段也在那里），版本号怎么推出在 `_signing.sh` 的 `release_versions`，权限以 `App/Config/*.entitlements` 为准。

只能在网页上做的一次性前置（`<前缀>` 见下一小节）：创建 App Group `group.<前缀>` 与 iCloud 容器 `iCloud.<前缀>` 并挂到 App ID（主 App 与通知服务扩展 `<前缀>.notify` 都要挂）；Developer ID Application 证书（账号持有人创建，CSR 由 `provision.py devid-csr` 生成）；App Store Connect 里的 App 记录。

### 换成自己的身份（fork）

身份前缀只有一处：`App/Config/Signing.xcconfig` 的 `CUEPAD_APP_ID`（正式版是 `com.sugeh.cuepad`，fork 别沿用）。各 target 的 bundle id（`<前缀>`、`.share`、`.widget`、`.notify`、`.tests`）、权限文件、Info.plist、Swift 运行期与脚本都从它派生，改这一行即可。
团队写在凭据文件的 `CUEPAD_TEAM_ID`（字段见 `_signing.sh` 头注释）。本机 ad-hoc 构建到此就能编能跑。
要真机、同步或发布，再在开发者后台做上面的一次性前置：`xc.sh provision ids` 用 API 建四个 App ID 并开能力；App Group、iCloud 容器在网页创建并挂上；`xc.sh provision` 建证书与描述文件；CloudKit 结构按下文导入自己的容器。
Mac 的自动更新源与公钥（`CuePad-macOS-Info.plist` 的 `SUFeedURL`、`SUPublicEDKey`）指向本仓库的发布，自己发版时换成自己的（`sparkle.sh`）。
门铃中转（同一文件的 `CUEPAD_RELAY_HOST`）默认是作者的 `relay.cue-pad.com`，fork 照用也和别人互不相干（房间由各自 iCloud 里的密钥派生）；换成自己架的见 `relay/README.md`。发布脚本打包前核对它的 `/health`。

## 自动更新（macOS）

Sparkle 2：密钥、appcast 与只发完整包见 `sparkle.sh` 头注释，更新源与公钥在 `App/Config/CuePad-macOS-Info.plist`。

下载位置只有一处：GitHub `Suge8/CuePad` 里一个固定的 Release（标签 `v0.1.0`），`release mac` 每次原地替换资产，都经 `releases/latest/download/<文件名>` 访问，更新链不经过官网：

| 资产 | 用途 |
| --- | --- |
| `CuePad-mac-arm64.zip` | 官网下载按钮的固定地址 |
| `appcast.xml` | 更新源，只含最新这一版 |
| `CuePad-mac-arm64-<构建号>.zip` | 与官网包同一个文件，appcast 的 enclosure 指向它 |

enclosure 带构建号，是因为 GitHub 不能一次替换多个资产：用固定名字时，换包与换 appcast 之间有一段旧签名配新包的窗口，落后的客户端验签失败。所以上传顺序是：带构建号的新包 → `appcast.xml` → 官网包 → 删上一版带构建号的包；中途失败重跑 `release mac` 即可补齐。

装更新要重启 CuePad：托管的 Pi 撑得过重启（新版经桥认回），Claude Code、Codex、OpenCode 这类随 App 退出的托管会话还在干活或等你确认时，重启推迟到它们空下来（`UpdateService`）。`-CuePadScene updatewait` 验托管的 Pi 在干活时更新直接装。

换 logo 时重跑 `scripts/make-icon.py`，菜单栏图标 `cue.menubar` 在符号生成器里一起改。

## CloudKit 数据结构

`apple/CloudKit/cuepad.ckdb` 由同步记录映射推出：映射改了 `CloudKitSchemaTests` 会失败，用 `TEST_RUNNER_CUEPAD_REGENERATE_SCHEMA=1 apple/scripts/xc.sh test kit '-only-testing:CueSyncTests/CloudKitSchemaTests/regenerateSchemaFile()'` 重新生成，再导入开发环境。管理令牌在钥匙串 `cuepad-cloudkit-management-token`（过期时在这里更新），不入库、不打印：

```bash
export CLOUDKIT_MANAGEMENT_TOKEN=$(security find-generic-password -a cuepad -s cuepad-cloudkit-management-token -w)
set -a; . ~/.appstoreconnect/cuepad.env; set +a   # CUEPAD_TEAM_ID
C="--team-id $CUEPAD_TEAM_ID --container-id iCloud.$(sed -n 's/^CUEPAD_APP_ID *= *//p' apple/App/Config/Signing.xcconfig) --environment development"
xcrun cktool validate-schema $C --file apple/CloudKit/cuepad.ckdb
xcrun cktool import-schema $C --validate --file apple/CloudKit/cuepad.ckdb
xcrun cktool export-schema $C --output-file /tmp/dev.ckdb   # 回读：服务端按字母序重排并补系统字段，逐类型核对字段与权限
```

生产环境只能在 CloudKit 控制台网页点「Deploy Schema Changes」部署开发环境的结构（cktool 不能部署），由 agent 自己做，不找用户：

1. 部署前回读开发与生产（生产加 `--environment production`）与 `cuepad.ckdb` 逐类型对比：开发环境除系统的 `Users` 外与 `cuepad.ckdb` 一致（别的检出导入过的试验类型会随部署永久进生产；重新导入 `cuepad.ckdb` 会把它们从开发环境去掉）。
2. 用 better-browser-use 的 `--mine` 车道（用户自己已登录 Apple 开发者账号的浏览器）打开控制台，开发环境点「Deploy Schema Changes…」，确认页列出的改动只有这次新增的，再点 Deploy。
3. 再回读生产与 `cuepad.ckdb` 对比；交回时附确认页与部署完成的截图。

发布带新字段或新记录类型的版本前先部署：生产里写未部署的字段或类型会让整条记录保存失败。`release mac|ios` 打包前由 `ck-production.sh` 核对，缺字段就不发。生产结构只能增不能删：已下线的类型与字段在 `CloudKitSchema.retiredTypes` / `retiredFields` 照原样声明。

订阅分两半：定义随 schema 部署，每台手机的订阅由 App 自己建（`AlertSubscriptions`，启动、账号变化、回前台时补建）。Apple 的 `CKSubscription` 文档："Create subscriptions in the development environment first and then promote them to production. Attempting to create a subscription directly in the production environment results in an error." 本项目 2026-10-07 在生产实测：没部署过的查询订阅被拒（CKErrorDomain 12，底层 BadSyntax 2006，"attempting to create a subscription in a production container"），数据库订阅不受限；按通知形状匹配（换成 alertBody 的变体会被拒）。订阅不在 `.ckdb` 里，cktool 看不到。改定义（谓词、选项、通知文案 key、content-available）的部署办法：开发环境签名的构建在开发容器里保存同样的订阅（同步区也用 `CuePad`），再在控制台 Deploy Schema Changes。确认页各项都显示 0、也不列出订阅，但部署照样生效。

### 待部署到生产

发版前一次 Deploy Schema Changes，部署完删掉对应条目。这里记的是 cktool 看不到的订阅定义，订阅只有手机会建：这一节还有条目时 `release ios` 拒绝发版，`release mac` 不受影响：

- 字段（都是 ENCRYPTED STRING，已导入开发环境）：`deliveryRequests.failure`、`cueMessages.shownText`、`piMessages.shownText`（没送到的原因、CuePad 代 Cue 写下的话、确认框的作答改存句式与参数，`ShownText`；`deliveryRequests.resultDetail` 下线），`cueMessages.places`（对话写下时提到的那几处的样子，`CuePlace`）。没部署时带这些字段的请求、Cue 对话与会话消息在生产里存不上。
- 订阅定义（2026-10-26 已在开发容器里保存并回读核对）：`cuepad.cue.said` 的谓词从 `author == cue` 改成 `notify == said`（`CuePush`：带提示的 Cue 消息原先同时命中它与 `cuepad.cue`，推两次）。新版手机按同一 ID 原地换掉旧定义；`cueMessages.author` 的可查询索引为旧版手机留着（`AlertSubscriptions.legacyQueried`），数据结构文件不变。发版前在控制台 Deploy Schema Changes。没部署时新版手机建不成它，不出通知的 Cue 消息不再静默叫醒手机，可见通知照常。
- 订阅定义（2026-10-26 已在开发容器里保存）：新增 `cuepad.pi.reply`（Cue 留给你回的会话，`notify == awaitsReply`，文案 key `pi_alert_reply`）。部署后再发 iOS 版。没部署时生产里建不成它，待回复的锁屏推送不来，别的照常。
