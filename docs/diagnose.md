# 崩溃诊断与真机日志

## 崩溃

- 手机连着这台 Mac（`xcrun devicectl list devices` 里是 available，无线也行）时自己拉：`xc.sh diag ios crashes` 把手机上 CuePad 的系统崩溃报告（连同记下 CuePad 被内存回收的 JetsamEvent）拷到 `apple/.derived/diag/<UDID>/`，按构建号与 UUID 找发布归档的 dSYM 还原 CuePad 自己的帧，打出与"导出诊断"同一套要点；拷出不删手机上的。没有 CuePad 的就列出别的，`all` 连它们一起解析。用户发来的或 Mac 上的 `.ips` 用 `xc.sh diag ips <文件…>`。手机重启后第一次连，devicectl 会自己挂上开发者镜像（Xcode 连真机时也这样）。
- 手机不在身边时，才请用户从设置的"上次崩溃"里"导出诊断"发来：复制的是 App 存档（MetricKit）里每份的要点（本地时间、版本、设备、异常与终止原因的人话、崩溃线程前几帧，CuePad 自己的帧标 `← CuePad`），同一种并成一条计次数；要完整 JSON 再请用户点"分享原始文件…"。App 自己看守记下的"主线程卡住"只在这里有，系统的崩溃报告里没有。这些帧未符号化，靠 dSYM 还原，每次发布的归档在 `~/Library/Developer/Xcode/Archives/<日期>/CuePad <ios|mac> <构建号>.xcarchive`（`dwarfdump --uuid` 对上 UUID 后 `atos -o <dSYM 里的 DWARF> -l <载入地址>`；系统库要那台设备系统版本的符号）。
- 0x8BADF00D 加 `WatchdogEvent: process-exit` 多半是主线程先卡住、用户再从后台划掉：看同一份摘要里的"主线程卡住"（App 内的看守记下的：卡住时在哪一页、之前开合过什么）。
- 偶发的卡死用 `xc.sh explore [种子] [秒]` 找：随机点滑三页，看守一记下卡住就停手连取样本，记录可按种子回放（`explore.py` 头注释）。验看守本身用 `-CuePadFreeze <秒>`。
- 模拟器里 `xc.sh shot`/`rec` 报"App 在画面就绪前退出了"就是崩了，报告在 `~/Library/Logs/DiagnosticReports/CuePad-*.ips`。只在会话跑着时崩的，用 `-CuePadStream YES` 让它一轮一轮跑起来。

## 真机复现时边操作边看日志

1. 日志走 usbmuxd，不走崩溃报告那条无线连接：手机用线连着这台 Mac（解锁、点信任），或请用户在 Finder 里选中这台手机、勾上"通过 Wi-Fi 连接时显示此 iPhone"，之后无线也行。为什么不用别的取法见 `device_diag.py` 头注释。
2. 先告诉用户"现在开始复现，做完说一声"，再跑 `xc.sh diag ios logs <跟的秒数> [回看的秒数]`：先等跟的秒数，再从手机取日志，只留 [开始−回看, 结束] 里 CuePad 的（进程名 CuePad 开头、子系统是 App 身份，加 runningboardd 关于它的起停），写成 `apple/.derived/diag/<UDID>/logs-<窗口>.log`，打出条数与按进程、级别的计数。用户已经复现完了就 `logs 0 <回看的秒数>`。
3. 换窗口或换过滤不用再取：整份日志留在同一目录的 `last.logarchive`，`log show --archive <它> --start … --end … --predicate …` 再截。
4. 日志里可能有用户的内容：只留在本机，回给用户与写进报告的只放条数和脱敏后的样子。崩了的话接着跑一次 `xc.sh diag ios crashes`。
