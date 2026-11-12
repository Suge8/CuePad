# 脚本

每个脚本的用法在它的头注释里，命令表是 `xc.sh help`。这里只有做错了伤到用户数据、线上用户或正式版，而脚本拦不住的事。

## 真实数据复现

首帧、滚动、输入类问题在演示库上好了不算修好：条数、正文长短与图片和真实库差得远。在真实库的只读副本上复现：

```bash
mkdir -p /tmp/cuepad-copy
sqlite3 -readonly "<库目录>/cuepad.db" ".backup /tmp/cuepad-copy/cuepad.db"   # 库目录见 LibraryLocation
mkdir -p /tmp/cuepad-copy/Caches && cp -cR ~/Library/Caches/CuePadAttachments /tmp/cuepad-copy/Caches/   # 要看附件时：本机那份
cp -cR "<库目录>/Attachments" /tmp/cuepad-copy/   # 还没上传的保底
CUEPAD_SHOT_LIBRARY=/tmp/cuepad-copy apple/scripts/xc.sh shot mac …
```

`.backup` 在正式版开着库时也拷得出一致的一份；直接 `cp` 会漏掉 WAL 里没落盘的写入。副本里是用户的私人内容，验完删掉 `/tmp/cuepad-copy`。

## 占前台

占前台会抢用户的键盘、移指针：只在要和交互预算比的数字上用，一次量够、不连跑；新加的要占前台的自动化只经 `DebugForeground`。

## 共用的东西

- 机器上常开着正式版和别的检出的实例：bcu、xctrace 只按 PID 认，按名字或 bundle id 会认到正式版。
- 模拟器槽位全机共用：在里面改过的系统设置（旁白、语言、减少动态效果）验完还原再 `xc.sh stop`，否则下一个任务接着带着。
- 真机日志（`xc.sh diag`）里可能有用户的内容：只在本机读，回给用户与写进报告的只放条数和脱敏后的样子。

## 通知

产物目录里的构建拿不到通知权限（日志 `Failed to find or validate client`）：复制成 `~/Applications/CuePad Notify.app`（别的名字，不覆盖用户装的 `CuePad.app`），改掉 `CFBundleIdentifier` 再 ad-hoc 重签名，用 `open -n -g --env …` 带上 `app_env.py` 的 `isolated_env` 那几个目录启动；验完删掉副本。

## 查日志

App 日志的 subsystem 是 App 身份前缀（`Signing.xcconfig` 的 `CUEPAD_APP_ID`），类别：`sync` 同步失败，`relay` 门铃，`delivery` 投送请求在 Mac 上的到达与领取，`services` 手机上传用时，`stall` Mac 拉取停摆，`live-activity` 实时活动。CloudKit 自己的在 `com.apple.cloudkit`。

```bash
id=$(sed -n 's/^CUEPAD_APP_ID *= *//p' apple/App/Config/Signing.xcconfig)
log show --last 30m --info --debug --predicate "subsystem == \"$id\" OR (process == \"CuePad\" AND subsystem BEGINSWITH \"com.apple.cloudkit\")"
```

## 签名

只能在网页上做的一次性前置：创建 App Group `group.<前缀>` 挂到主 App、`<前缀>.share`、`<前缀>.widget` 的 App ID；创建 iCloud 容器 `iCloud.<前缀>` 挂到主 App 与 `<前缀>.notify` 的 App ID；Developer ID Application 证书（只有账号持有人能建，CSR 由 `provision.py devid-csr` 生成）；App Store Connect 里的 App 记录；CloudKit 管理令牌（CloudKit 控制台建，存进钥匙串 `-a cuepad -s cuepad-cloudkit-management-token`，不入库、不打印）。

### 换成自己的身份（fork）

改 `App/Config/Signing.xcconfig` 的 `CUEPAD_APP_ID`（即上面的 `<前缀>`，别沿用 `com.sugeh.cuepad`），团队写凭据文件的 `CUEPAD_TEAM_ID`；然后 `xc.sh provision ids` → 上面的网页前置 → `xc.sh provision` → 按下文把 CloudKit 结构导入自己的容器。自己发 Mac 版前必须把 `CuePad-macOS-Info.plist` 的 `SUFeedURL`、`SUPublicEDKey` 换成自己的（`sparkle.sh`），否则更新指向本仓库的发布。

## CloudKit 数据结构

`apple/CloudKit/cuepad.ckdb` 重新生成后导入开发环境：

```bash
export CLOUDKIT_MANAGEMENT_TOKEN=$(security find-generic-password -a cuepad -s cuepad-cloudkit-management-token -w)
set -a; . ~/.appstoreconnect/cuepad.env; set +a   # CUEPAD_TEAM_ID
C="--team-id $CUEPAD_TEAM_ID --container-id iCloud.$(sed -n 's/^CUEPAD_APP_ID *= *//p' apple/App/Config/Signing.xcconfig) --environment development"
xcrun cktool import-schema $C --validate --file apple/CloudKit/cuepad.ckdb
xcrun cktool export-schema $C --output-file /tmp/dev.ckdb
```

生产环境只能在 CloudKit 控制台网页点「Deploy Schema Changes」部署（cktool 不能），由 agent 用 browser skill 的 `bbu --mine <已登录 Apple 开发者账号的账户>` 自己做，不找用户：

1. 部署前回读开发与生产（`--environment production`），开发环境除系统的 `Users` 外必须与 `cuepad.ckdb` 一致：别的检出导入过的试验类型会随部署永久进生产，重新导入 `cuepad.ckdb` 能把它们从开发环境去掉。
2. 确认页列出的改动只有这次新增的，再点 Deploy。
3. 跑 `apple/scripts/ck-production.sh` 核对生产不缺字段。

查询订阅不在 `.ckdb` 里、cktool 看不到，却随 schema 部署：生产里没部署过的查询订阅建不了（CKErrorDomain 12，"attempting to create a subscription in a production container"），已部署的按通知形状匹配，所以改定义（谓词、选项、通知文案 key、content-available）后，先用开发签名的构建在开发容器里保存同样的订阅，再 Deploy Schema Changes。确认页显示 0 项、不列订阅，部署照样生效。数据库订阅不受此限。

改了订阅定义、还没部署到生产时，在 `apple/CloudKit/pending-production.txt` 记一行：有条目时 `release ios` 拒绝发版，部署并回读核对后删掉。
