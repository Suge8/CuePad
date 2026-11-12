# 崩溃诊断与真机日志

先分出事的是哪台：出在这台 Mac 上就直接读这台的系统日志（下一节），出在手机、iPad（或别的 Mac）上就看经 iCloud 送到这台的文件（再下一节）。

## 出在这台 Mac 上

`log show --predicate 'subsystem == "<App 身份>"' --last 15m --info`（App 身份是 `Signing.xcconfig` 的 `CUEPAD_APP_ID`；`--debug` 连调试级一起，`--start`/`--end` 换时段）。比手机送来的 15 分钟快照全：不限条数，也读得到上次运行的。同一台上开着 `xc.sh` 起的隔离实例时，它们的日志也是这个子系统，加 `AND processID == <PID>` 分开。Mac 的诊断存档（崩溃、卡死、主线程卡住）在资料库目录里，不直接读：它们照样经 iCloud 送出、落到 `~/Library/Logs/CuePad/<这台 Mac 的电脑名>/`，按下一节读。

## 出在手机、iPad 上：经 iCloud 送到 Mac

1. 复现一个问题时请用户：复现完在 iPhone、iPad 的设置里点"把最近日志发到 Mac"（"上次崩溃"那一节；Mac 上没有这一行，见上一节）。它存一份 CuePad 最近 15 分钟的日志、立即送出；Mac 最多 5 分钟后落盘。iCloud 一时连不上时显示"已存下"，之后自己送出。
2. `xc.sh diag` 看那台收到了没有，`xc.sh diag <设备>` 读要点与日志。日志里可能有用户的内容：只在本机读，回给用户与写进报告的只放条数和脱敏后的样子。

没收到时：两台登的是不是同一个 iCloud、设置里同步是不是好的；手机上点了"把最近日志发到 Mac"显示"已发出"后 5 分钟 Mac 上还没有，看 Mac 的日志（子系统 App 身份、分类 `diagnostics`）。MetricKit 的崩溃一般下次启动或隔天才交来，所以崩溃比日志晚到。

## 现场补充：手机连着这台 Mac

- 系统自己的崩溃报告与 MetricKit 互补：带全部线程，用 `xc.sh diag ios crashes` 拉。手机重启后第一次连，devicectl 会自己挂上开发者镜像（Xcode 连真机时也这样）。
- 不做直连取手机的系统日志：idevicesyslog 要用户在 Finder 里另开"通过 Wi-Fi 连接时显示此 iPhone"或插线，pymobiledevice3 无线下要另配对或搭会挤掉 Xcode 连接的隧道。要系统层面的（别的进程、内核）请用户插线后在 Mac 的"控制台"App 里选这台手机看。

## 别人发来的与其他

- 手机与 Mac 都不在手边、或要发给别人时，请用户从设置的"上次崩溃"里"导出诊断"：复制的是存档里每份的要点（格式同 `xc.sh diag <设备>`）；要完整 JSON 再请用户点"分享原始文件…"。用户发来的系统崩溃报告（.ips）用 `xc.sh diag ips <文件>` 解析、符号化。
- 0x8BADF00D 加 `WatchdogEvent: process-exit` 多半是主线程先卡住、用户再从后台划掉：看同一份摘要里的"主线程卡住"（卡住时在哪一页、之前开合过什么）与它附的日志。
- 模拟器里只在会话跑着时崩的，用 `-CuePadScene session -CuePadStream YES` 让它一轮一轮跑起来。
- 验收送达不连真 iCloud：`xc.sh fleet up -- -CuePadSampleCrash YES`（三端各存几份照抄真机的样例诊断；Mac 每 5 秒收一次），在 iPhone 的设置里点"把最近日志发到 Mac"，`CUEPAD_DIAG_DIR=apple/.derived/fleet/mac/library/Logs xc.sh diag [iPhone]`。模拟器用它模拟的型号代号。
