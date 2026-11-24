# 签名

只能在网页上做的一次性前置：创建 App Group `group.<前缀>` 挂到主 App、`<前缀>.share`、`<前缀>.widget`、`<前缀>.notify` 的 App ID；创建 iCloud 容器 `iCloud.<前缀>` 挂到主 App 与 `<前缀>.notify` 的 App ID；Developer ID Application 证书（只有账号持有人能建，CSR 由 `provision.py devid-csr` 生成）；App Store Connect 里的 App 记录；CloudKit 管理令牌（CloudKit 控制台建，存进发布用的专用钥匙串 `provision.py unlock` 的 `-a cuepad -s cuepad-cloudkit-management-token`，不入库、不打印）。

## 云端发 Mac 版

合并后主干云端全绿，`.github/workflows/release.yml` 自己发 Mac 版，凭据取自 GitHub 仓库设置里发布环境 `release` 的机密 `RELEASE_HOME`。这个环境只放行 `main`：分支与复刻提的改动请求拿不到它。凭据、证书或钥匙串里的任一样换了，跑 `xc.sh release secrets` 重存一份。

## 换成自己的身份（fork）

改 `App/Config/Signing.xcconfig` 的 `CUEPAD_APP_ID`（即上面的 `<前缀>`，别沿用 `com.sugeh.cuepad`），团队写凭据文件的 `CUEPAD_TEAM_ID`；然后 `xc.sh provision ids` → 上面的网页前置 → `xc.sh provision` → 把 CloudKit 结构导入自己的容器（`apple/CloudKit/AGENTS.md`）。自己发 Mac 版前必须把 `CuePad-macOS-Info.plist` 的 `SUFeedURL`、`SUPublicEDKey` 换成自己的（`sparkle.sh`），否则更新指向本仓库的发布。
