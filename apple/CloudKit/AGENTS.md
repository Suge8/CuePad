# CloudKit 数据结构

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
