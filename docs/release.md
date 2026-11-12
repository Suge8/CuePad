# 签名、发布与 CloudKit 结构

## 发版核对

- 待公证、上传结果未知的旧尝试原样保留（`apple/.derived/release/<平台>-attempts/`），确认不再需要恢复后才手动清理；不手改保留的产物。
- 下一次 `release ios` 是新构建，不是重试上一份；上传结果未知时保留原尝试并核实 App Store Connect，不自动重投。

## 发版顺序

同步下界（`Schema.peerFloor`）抬高的那一版先发 iOS 的理由：Mac 经 Sparkle 几分钟就装上，iOS 要等苹果处理十几分钟到一小时，反过来发，这段时间里手机停下收发。下界没变的版本先后随意。

每次发 Mac 都把这一版装进本机 `~/Applications/CuePad.app` 并重启到新版（导出的包在这次尝试目录的 `export/CuePad.app`），不等 Sparkle；交回时写装上的 `CFBundleVersion`，没装上就说原因。

## 签名

只能在网页上做的一次性前置（`<前缀>` 见下一小节）：创建 App Group `group.<前缀>` 与 iCloud 容器 `iCloud.<前缀>` 并挂到 App ID（主 App 与通知服务扩展 `<前缀>.notify` 都要挂）；Developer ID Application 证书（账号持有人创建，CSR 由 `provision.py devid-csr` 生成）；App Store Connect 里的 App 记录。

### 换成自己的身份（fork）

身份前缀只有一处：`App/Config/Signing.xcconfig` 的 `CUEPAD_APP_ID`（正式版是 `com.sugeh.cuepad`，fork 别沿用）。各 target 的 bundle id（`<前缀>`、`.share`、`.widget`、`.notify`、`.tests`）、权限文件、Info.plist、Swift 运行期与脚本都从它派生，改这一行即可。
团队写在凭据文件的 `CUEPAD_TEAM_ID`（字段见 `_signing.sh` 头注释）。本机 ad-hoc 构建到此就能编能跑。
要真机、同步或发布，再在开发者后台做上面的一次性前置：`xc.sh provision ids` 用 API 建四个 App ID 并开能力；App Group、iCloud 容器在网页创建并挂上；`xc.sh provision` 建证书与描述文件；CloudKit 结构按下文导入自己的容器。
Mac 的自动更新源与公钥（`CuePad-macOS-Info.plist` 的 `SUFeedURL`、`SUPublicEDKey`）指向本仓库的发布，自己发版时换成自己的（`sparkle.sh`）。

## 自动更新（macOS）

下载位置只有一处：GitHub `Suge8/CuePad` 里一个固定的 Release（标签 `v0.1.0`），都经 `releases/latest/download/<文件名>` 访问，更新链不经过官网：

| 资产 | 用途 |
| --- | --- |
| `CuePad-mac-arm64.zip` | 官网下载按钮的固定地址 |
| `appcast.xml` | 更新源，只含最新这一版 |
| `CuePad-mac-arm64-<构建号>.zip` | 与官网包同一个文件，appcast 的 enclosure 指向它 |

- enclosure 带构建号，是因为 GitHub 不能一次替换多个资产：用固定名字时，换包与换 appcast 之间有一段旧签名配新包的窗口，落后的客户端验签失败。所以上传顺序是：带构建号的新包 → `appcast.xml` → 官网包 → 删上一版带构建号的包；中途失败用 `--resume <公证 id>` 补齐。
- `mac/<构建号>` 标签先于资产推送，标签在不代表上传与回读已完成。

换图标：改 `AppIcon.icon` 里的 `cue.png`，着色与透明外观的剪影、落地页的小标重跑 `design/tools/cue-symbols.py`（连同菜单栏与图标族里的 Cue，几何只在 `design/tools/ink/mascot.py`），落地页的 `icon.png`（64）与 `apple-touch-icon.png`（180，垫墨色底）用 Icon Composer 的 `ictool` 导出。

## CloudKit 数据结构

`apple/CloudKit/cuepad.ckdb` 重新生成后导入开发环境。管理令牌过期时在钥匙串里更新，不入库、不打印：

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
2. 用 browser skill 的 `bbu --mine`（用户自己已登录 Apple 开发者账号的浏览器）打开控制台，开发环境点「Deploy Schema Changes…」，确认页列出的改动只有这次新增的，再点 Deploy。
3. 再回读生产与 `cuepad.ckdb` 对比；交回时附确认页与部署完成的截图。

订阅定义随 schema 部署，每台手机的订阅由 App 自己建（`AlertSubscriptions`）。Apple 的 `CKSubscription` 文档："Create subscriptions in the development environment first and then promote them to production. Attempting to create a subscription directly in the production environment results in an error." 生产里没部署过的查询订阅被拒（CKErrorDomain 12，底层 BadSyntax 2006，"attempting to create a subscription in a production container"），数据库订阅不受限；按通知形状匹配（换成 alertBody 的变体会被拒）。订阅不在 `.ckdb` 里，cktool 看不到。改定义（谓词、选项、通知文案 key、content-available）的部署办法：开发环境签名的构建在开发容器里保存同样的订阅（同步区也用 `CuePad`），再在控制台 Deploy Schema Changes。确认页各项都显示 0、也不列出订阅，但部署照样生效。

### 待部署到生产

这一节还有条目时 `release ios` 拒绝发版；部署完成并回读核对后删除对应条目。字段由 `ck-production.sh` 另行核对。
