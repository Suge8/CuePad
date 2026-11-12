# 签名、发布与 CloudKit 结构

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

### 待部署到生产

这一节还有条目时 `release ios` 拒绝发版；部署完成并回读核对后删除对应条目。字段由 `ck-production.sh` 另行核对。
