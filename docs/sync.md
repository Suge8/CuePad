# 同步排查

App 日志的 subsystem 是 App 身份前缀（`Signing.xcconfig` 的 `CUEPAD_APP_ID`），类别：`sync` 同步失败，`relay` 门铃，`delivery` 投送请求在 Mac 上的到达与领取，`services` 手机上传用时，`stall` Mac 拉取停摆，`live-activity` 实时活动。CloudKit 自己的在 `com.apple.cloudkit`。

```bash
id=$(sed -n 's/^CUEPAD_APP_ID *= *//p' apple/App/Config/Signing.xcconfig)
log show --last 30m --info --debug --predicate "subsystem == \"$id\" OR (process == \"CuePad\" AND subsystem BEGINSWITH \"com.apple.cloudkit\")"
```
