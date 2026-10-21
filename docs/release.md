# 签名、发布与 CloudKit 结构

入口是 `xc.sh release mac|ios`、`xc.sh device`、`xc.sh provision`，每步做什么在 `apple/scripts/` 下各脚本的头注释里（`release-mac.sh`、`release-ios.sh`、`provision.py`、`testflight.py`、`sparkle.sh`、`ck-production.sh`）。对外发布只在用户明确要求时做：发出去的包会推给所有用户。发布只在干净检出运行，否则 `xc.sh` 拒绝。

## 签名

签名的做法与理由在 `App/Config/Signing.xcconfig` 与 `scripts/_signing.sh` 的头注释里（凭据文件的字段也在那里），版本号怎么推出在 `_signing.sh` 的 `release_versions`，权限以 `App/Config/*.entitlements` 为准。

只能在网页上做的一次性前置（`<前缀>` 见下一小节）：创建 App Group `group.<前缀>` 与 iCloud 容器 `iCloud.<前缀>` 并挂到 App ID（主 App 与通知服务扩展 `<前缀>.notify` 都要挂）；Developer ID Application 证书（账号持有人创建，CSR 由 `provision.py devid-csr` 生成）；App Store Connect 里的 App 记录。

### 换成自己的身份（fork）

身份前缀只有一处：`App/Config/Signing.xcconfig` 的 `CUEPAD_APP_ID`（正式版是 `com.sugeh.cuepad`，fork 别沿用）。各 target 的 bundle id（`<前缀>`、`.share`、`.widget`、`.notify`、`.tests`）、权限文件、Info.plist、Swift 运行期与脚本都从它派生，改这一行即可。
团队写在凭据文件的 `CUEPAD_TEAM_ID`（字段见 `_signing.sh` 头注释）。本机 ad-hoc 构建到此就能编能跑。
要真机、同步或发布，再在开发者后台做上面的一次性前置：`xc.sh provision ids` 用 API 建四个 App ID 并开能力；App Group、iCloud 容器在网页创建并挂上；`xc.sh provision` 建证书与描述文件；CloudKit 结构按下文导入自己的容器。
Mac 的自动更新源与公钥（`CuePad-macOS-Info.plist` 的 `SUFeedURL`、`SUPublicEDKey`）指向本仓库的发布，自己发版时换成自己的（`sparkle.sh`）。

## 自动更新（macOS）

Sparkle 2：密钥、appcast 与只发完整包见 `sparkle.sh` 头注释，更新源与公钥在 `App/Config/CuePad-macOS-Info.plist`。

下载位置只有一处：GitHub `Suge8/CuePad` 里一个固定的 Release（标签 `v0.1.0`），`release mac` 每次原地替换资产，都经 `releases/latest/download/<文件名>` 访问，更新链不经过官网：

| 资产 | 用途 |
| --- | --- |
| `CuePad-mac-arm64.zip` | 官网下载按钮的固定地址 |
| `appcast.xml` | 更新源，只含最新这一版 |
| `CuePad-mac-arm64-<构建号>.zip` | 与官网包同一个文件，appcast 的 enclosure 指向它 |

enclosure 带构建号，是因为 GitHub 不能一次替换多个资产：用固定名字时，换包与换 appcast 之间有一段旧签名配新包的窗口，落后的客户端验签失败。所以上传顺序是：带构建号的新包 → `appcast.xml` → 官网包 → 删上一版带构建号的包；中途失败重跑 `release mac` 即可补齐。

装更新要重启 CuePad，会结束它托管的会话：还有托管会话在干活或等你确认时，重启推迟到它们空下来（`UpdateService`）。验收用 `-CuePadScene updatewait`。

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

发布带新字段或新记录类型的版本前先部署：生产里写未部署的字段或类型会让整条记录保存失败。`release mac` 打包前由 `ck-production.sh` 核对，缺的先部署再发。生产结构只能增不能删：已下线的类型与字段在 `CloudKitSchema.retiredTypes` / `retiredFields` 照原样声明。

订阅也是 schema 的一部分，但不在 `.ckdb` 里，cktool 看不到：生产环境拒绝客户端创建没部署过的查询订阅（CKErrorDomain 12，底层 BadSyntax 2006，"attempting to create a subscription in a production container"），区域与数据库订阅不受限；订阅按通知形状匹配（换成 alertBody 的变体会被拒）。改订阅的定义（谓词、选项、通知文案 key）要先让开发环境签名的构建在开发容器里保存同样的订阅，再在控制台 Deploy Schema Changes——确认页各项都显示 0、也不列出订阅，但部署照样生效。

待部署到生产（已导入开发环境，发版前按上面三步部署，部署完删掉对应条目）：

- 订阅 `cuepad.pi.waiting`、`cuepad.cue` 加 content-available（`AlertSubscriptions`，等你类推送叫醒 App 更新实时活动）：订阅不在 `.ckdb` 里，按上一段部署
