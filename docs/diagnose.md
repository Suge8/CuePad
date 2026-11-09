# 崩溃诊断与真机日志

先分出事的是哪台：出在这台 Mac 上就直接读这台的系统日志（下一节），出在手机、iPad（或别的 Mac）上就看经 iCloud 送到这台的文件（再下一节）。

## 出在这台 Mac 上

`log show --predicate 'subsystem == "<App 身份>"' --last 15m --info`（App 身份是 `Signing.xcconfig` 的 `CUEPAD_APP_ID`；`--debug` 连调试级一起，`--start`/`--end` 换时段）。比手机送来的 15 分钟快照全：不限条数，也读得到上次运行的。同一台上开着 `xc.sh` 起的隔离实例时，它们的日志也是这个子系统，加 `AND processID == <PID>` 分开。Mac 的诊断存档（崩溃、卡死、主线程卡住）在资料库目录里，不直接读：它们照样经 iCloud 送出、落到 `~/Library/Logs/CuePad/<这台 Mac 的电脑名>/`，按下一节读。

## 出在手机、iPad 上：经 iCloud 送到 Mac

1. 每台设备（iPhone、iPad、Mac）上的 CuePad 把诊断存在本机（MetricKit 交来的崩溃、卡死、CPU 与磁盘异常，App 的看守记下的主线程卡住；`DiagnosticArchive`，最近 10 份，其中日志至多 3 份），存档一变就经用户自己的 iCloud 私有库送出（独立的 `Diagnostics` 区、记录类型 `deviceDiagnostics`，内容加密，覆盖写；删掉的云上也删）。与同步共用一份限流：被限流时一起等服务器给的时刻。没送成的（断网、被限流）自己隔 30 秒起、加倍至 10 分钟再送，送成为止。
2. 用户登着同一个 iCloud 的 Mac 上的 CuePad 每 5 分钟收一次（同步认好账号后先收一次），落成 `~/Library/Logs/CuePad/<设备>/<时刻>-<种类>.json|.log`（`DiagnosticInbox`）。`<设备>` 是 Mac 的电脑名，iPhone、iPad 是型号代号（如 iPhone18,1：iOS 不给 App 用户起的设备名）。这个目录不在资料库里，读它不碰真实资料库；`xc.sh` 起的隔离实例经 `CUEPAD_DEVICE_LOGS_DIR` 落在自己库的 `Logs/`（`app_env.py` 的 `isolated_env`）。
3. agent 读：`xc.sh diag` 列各台收到几份、最新的是什么；`xc.sh diag <设备开头几个字>` 打出与"导出诊断"同一套要点，CuePad 的帧按构建号与 UUID 找发布归档（`~/Library/Developer/Xcode/Archives/<日期>/CuePad <ios|mac> <构建号>.xcarchive`）的 dSYM 还原，再列日志的路径、时段、条数与级别；`all` 连日志全文一起打出。日志里可能有用户的内容：只在本机读，回给用户与写进报告的只放条数和脱敏后的样子。
4. 复现一个问题时请用户：复现完在 iPhone、iPad 的设置里点"把最近日志发到 Mac"（"上次崩溃"那一节；Mac 上没有这一行，见上一节）。它存一份 CuePad 最近 15 分钟的日志（只读本进程、子系统是 App 身份的；标成私密的值系统已打码成 `<private>`，不绕开；超过 512KB 丢最早的），立即送出；Mac 最多 5 分钟后落盘。iCloud 一时连不上时显示"已存下"，之后自己送出。
5. 主线程卡住后恢复了的，自动附一份卡住前 1 分钟到恢复时的日志（`<同一时刻>-freeze-log.log`）；没恢复就被结束的附不上：`OSLogStore` 只读得到本进程这次运行的日志。

没收到时：两台登的是不是同一个 iCloud、设置里同步是不是好的；手机上点了"把最近日志发到 Mac"显示"已发出"后 5 分钟 Mac 上还没有，看 Mac 的日志（子系统 App 身份、分类 `diagnostics`）。MetricKit 的崩溃一般下次启动或隔天才交来，所以崩溃比日志晚到。收下的文件被手动删了又想要回来：删掉那个目录下的 `.inbox.json`（收件进度），Mac 下一次收件就从头重拉，照云上现有的全部重写。

MetricKit 帧的 `offsetIntoBinaryTextSegment` 是二进制内的偏移：2611060241 在 iOS 27.2 真机交来的那份（`-CuePadSampleCrash` 照抄它的 UUID 与偏移）按发布归档还原成 `AnswerBubble` 的值见证函数，落在 SwiftUI 更新视图的栈里。有报告说早期系统在这里放的是载入地址，`xc.sh diag` 两种都认（`diag_inbox.py` 的 `symbolicate_metrickit`）。

## 现场补充：手机连着这台 Mac

- 系统自己的崩溃报告（与 MetricKit 互补：带全部线程，含 CuePad 被内存回收的 JetsamEvent）：`xc.sh diag ios crashes` 经 devicectl（无线也行，不要 root）拷到 `apple/.derived/diag/<UDID>/`、符号化、打出要点；拷出不删手机上的。没有 CuePad 的就列出别的，`all` 连它们一起解析。用户发来的或 Mac 上的 `.ips` 用 `xc.sh diag ips <文件…>`。手机重启后第一次连，devicectl 会自己挂上开发者镜像（Xcode 连真机时也这样）。
- 不做直连取手机的系统日志：devicectl 没有日志流，`device sysdiagnose` 要管理员密码，`log collect --device` 要 root，idevicesyslog 要用户在 Finder 里另开"通过 Wi-Fi 连接时显示此 iPhone"或插线，pymobiledevice3 无线下要另配对或搭会挤掉 Xcode 连接的隧道。要系统层面的（别的进程、内核）请用户插线后在 Mac 的"控制台"App 里选这台手机看。

## 别人发来的与其他

- 手机与 Mac 都不在手边、或要发给别人时，请用户从设置的"上次崩溃"里"导出诊断"：复制的是存档里每份的要点（本地时间、版本、设备、异常与终止原因的人话、崩溃线程前几帧，CuePad 自己的帧标 `← CuePad`），同一种并成一条计次数；要完整 JSON 再请用户点"分享原始文件…"。
- 0x8BADF00D 加 `WatchdogEvent: process-exit` 多半是主线程先卡住、用户再从后台划掉：看同一份摘要里的"主线程卡住"（卡住时在哪一页、之前开合过什么）与它附的日志。
- 偶发的卡死用 `xc.sh explore [种子] [秒]` 找：随机点滑三页，看守一记下卡住就停手连取样本，记录可按种子回放（`explore.py` 头注释）。验看守本身用 `-CuePadFreeze <秒>`。
- 模拟器里 `xc.sh shot`/`rec` 报"App 在画面就绪前退出了"就是崩了，报告在 `~/Library/Logs/DiagnosticReports/CuePad-*.ips`。只在会话跑着时崩的，用 `-CuePadStream YES` 让它一轮一轮跑起来。
- 验收送达不连真 iCloud：`xc.sh fleet up -- -CuePadSampleCrash YES`（三端各存几份样例诊断，照抄真机那份，CuePad 的帧能按 2611060241 的归档还原；Mac 每 5 秒收一次），在 iPhone 的设置里点"把最近日志发到 Mac"，`CUEPAD_DIAG_DIR=apple/.derived/fleet/mac/library/Logs xc.sh diag [iPhone]`。模拟器用它模拟的型号代号。端到端测试是 `DiagnosticDeliveryTests`（存满十份删旧、卡住记录改写后重送、断网后自己补送）。
