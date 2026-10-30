# 签名、发布与 CloudKit 结构

入口是 `xc.sh release mac|ios`、`xc.sh device`、`xc.sh provision`，每步做什么在 `apple/scripts/` 下各脚本的头注释里（`release-mac.sh`、`release-ios.sh`、`provision.py`、`testflight.py`、`sparkle.sh`、`ck-production.sh`）。对外发布只在用户明确要求时做：发出去的包会推给所有用户。发布只在干净检出运行，否则 `xc.sh` 拒绝。

## 发版核对

`release mac` 导出后、公证前由脚本核对，不过就停：门铃中转活着、签名完整、包里的正式版标记 `CuePadRelease` 是 YES（`Signing.xcconfig` 的 `CUEPAD_RELEASE`，只有发版脚本归档时设）、包里的命令行在空家目录下去找正式资料库 `CuePad/Library` 而不是开发库 `CuePad Dev`。少了标记，装上的正式版会开开发库，用户看到的是空库。只核对、不上传用 `xc.sh release mac --dry-run`（照样提交公证）。

## 发版顺序

同步下界（`Schema.peerFloor`，什么时候抬见它的注释）抬高的那一版先发 iOS，等 TestFlight 处理完（`testflight.py builds` 显示 VALID）再发 Mac：Mac 经 Sparkle 几分钟就装上，iOS 要等苹果处理十几分钟到一小时，反过来发，这段时间里手机停下收发。`release ios` 上传后在那个提交上打 `ios/<构建号>` 标签，`release mac` 核对 TestFlight 上处理好的最新一版的下界不低于这一版，不够就不发。下界没变的版本通常先后随意；首次启用远程实时活动的这一版先更新负责发布的 Mac，再更新 iPhone：新版手机不再用本地库更新远程活动。

先装上新版的那台把下界抬上去，另一台停下同步、写下的照记，更新后自动发出：Mac 停下时当场查一次更新（`UpdateService.checkInBackground`），手机在设置的同步那一行点「在 TestFlight 里更新」。

## 签名

签名的做法与理由在 `App/Config/Signing.xcconfig` 与 `scripts/_signing.sh` 的头注释里（凭据文件的字段也在那里），版本号怎么推出在 `_signing.sh` 的 `release_versions`，权限以 `App/Config/*.entitlements` 为准。

只能在网页上做的一次性前置（`<前缀>` 见下一小节）：创建 App Group `group.<前缀>` 与 iCloud 容器 `iCloud.<前缀>` 并挂到 App ID（主 App 与通知服务扩展 `<前缀>.notify` 都要挂）；Developer ID Application 证书（账号持有人创建，CSR 由 `provision.py devid-csr` 生成）；App Store Connect 里的 App 记录。

### 换成自己的身份（fork）

身份前缀只有一处：`App/Config/Signing.xcconfig` 的 `CUEPAD_APP_ID`（正式版是 `com.sugeh.cuepad`，fork 别沿用）。各 target 的 bundle id（`<前缀>`、`.share`、`.widget`、`.notify`、`.tests`）、权限文件、Info.plist、Swift 运行期与脚本都从它派生，改这一行即可。
团队写在凭据文件的 `CUEPAD_TEAM_ID`（字段见 `_signing.sh` 头注释）。本机 ad-hoc 构建到此就能编能跑。
要真机、同步或发布，再在开发者后台做上面的一次性前置：`xc.sh provision ids` 用 API 建四个 App ID 并开能力；App Group、iCloud 容器在网页创建并挂上；`xc.sh provision` 建证书与描述文件；CloudKit 结构按下文导入自己的容器。
Mac 的自动更新源与公钥（`CuePad-macOS-Info.plist` 的 `SUFeedURL`、`SUPublicEDKey`）指向本仓库的发布，自己发版时换成自己的（`sparkle.sh`）。
中转地址由同一文件的 `CUEPAD_RELAY_HOST` 定义。作者的 `relay.cue-pad.com` 可供 fork 使用门铃（房间由各自 iCloud 密钥派生），但 APNs 只支持作者的 App topic；fork 的实时活动须部署自己的中转和匹配身份的 APNs 密钥，见 `relay/README.md`。发布脚本核对门铃 `/health` 与活动 `/v1/activity/health`；后者不代替实际投递验收。

## 自动更新（macOS）

Sparkle 2：密钥、appcast 与只发完整包见 `sparkle.sh` 头注释，更新源与公钥在 `App/Config/CuePad-macOS-Info.plist`。

下载位置只有一处：GitHub `Suge8/CuePad` 里一个固定的 Release（标签 `v0.1.0`），`release mac` 每次原地替换资产，都经 `releases/latest/download/<文件名>` 访问，更新链不经过官网：

| 资产 | 用途 |
| --- | --- |
| `CuePad-mac-arm64.zip` | 官网下载按钮的固定地址 |
| `appcast.xml` | 更新源，只含最新这一版 |
| `CuePad-mac-arm64-<构建号>.zip` | 与官网包同一个文件，appcast 的 enclosure 指向它 |

enclosure 带构建号，是因为 GitHub 不能一次替换多个资产：用固定名字时，换包与换 appcast 之间有一段旧签名配新包的窗口，落后的客户端验签失败。所以上传顺序是：带构建号的新包 → `appcast.xml` → 官网包 → 删上一版带构建号的包；中途失败重跑 `release mac` 即可补齐。

装更新要重启 CuePad：托管的 Pi 撑得过重启（新版经桥认回），Claude Code、Codex、OpenCode、Grok Build 这类随 App 退出的托管会话还在干活或等你确认时，重启推迟到它们空下来（`UpdateService`）。`-CuePadScene updatewait` 验托管的 Pi 在干活时更新直接装。

换图标：改 `AppIcon.icon` 里的 `cue.png`，着色与透明外观的剪影、落地页的小标重跑 `design/tools/cue-symbols.py`（连同菜单栏与图标族里的 Cue，几何只在它的 `mascot`），落地页的 `icon.png`（64）与 `apple-touch-icon.png`（180，垫墨色底）用 Icon Composer 的 `ictool` 导出。

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

这一节还有条目时 `release ios` 拒绝发版；部署完成并回读核对后删除对应条目。字段由 `ck-production.sh` 另行核对。
