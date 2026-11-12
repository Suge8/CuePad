# 同步参考

## 拉取节奏与门铃

- 实测（正式中转、CloudKit 开发环境）：服务器收下到对方入库，只靠按节奏拉中位 1.0～1.8 秒，门铃 0.5 秒；中转停掉 2 秒内发现并退回按节奏拉，起来后 4～8 秒连回。
- 中转放在香港自建：Cloudflare、Vercel 的默认域名在大陆遭 DNS 污染、按 SNI 阻断。
- Cue 值班是等待理由：不是的话，手机对 Cue 说的一句要等 Mac 别的理由才拉（曾 21 秒）。没开 1 秒一档：Cue 回一句本身要十几到几十秒。

## 用户离开时的 Mac

用户离开后 App Nap 把 App 放进后台节流档，别的程序占满 CPU 时整个进程拿不到 CPU，按节奏的拉取能停几分钟（正式版出现过 406 秒）。两样都要，缺一样仍会饿几十秒（加压实测：都不做拉取间隔最大 59.5 秒，只做后一样 39.8 秒，都做 2.9 秒）：

- 有等待理由期间持有系统活动（`AppServices.holdActivityWhilePolling`）：不持有时整个进程都在饿。
- 订阅重读走自己的只读连接（`CueStore` 头注释），外部提交按表叫醒（`ChangeNotification`），没人看得到主窗口时内容摘下（`MainShellWindow.parkWhileUnseen`）：持有活动后剩下的排队来自同一条队列上的活。

## 附件的文件

记录不等文件：同一批里等附件下完才应用时，只有字的灵感曾跟着 50MB 的文件等 17 秒。

没在真环境验证到的：

- 长期操作跨重启只在开发环境验过（`SYNC_BENCH_CLOUD=real sync-bench.py fileresume`：传到四成时杀掉再起，接上、不从头传）；被系统结束、手机上的后台传完没有在真机上验。
- 空间满只在模拟云验过（`sync-bench.py filesquota`）。真 iCloud 满了时不带文件的小记录会不会也被拒没有验证到。
- 按流量计费的网络下不自动取：这一条（判定来自系统的网络路径监视器）没有自动测试；自动取的其余条件由 `FileSyncTests` 覆盖。

## 说的话的链路

排查按以下链路定位：

1. 按发送 → 本机库：写下请求，显示发送中；没到服务器不到期、可撤回。
2. 本机 → 服务器：`CloudSync.send` 马上传；同步元数据证实收下才显示已发出。
3. 服务器 → Mac：门铃或拉取。
4. Mac → Agent：缺附件或会话没就绪时在旁边等，不挡其他会话；到期 Mac 写回失败，手机可重发。
5. Mac → 发出方：领取与结果立即上传。

## Mac 在线

在不在线（`MacPresence`）、开着哪些页（`Viewer`）、有哪些 Agent 与模型（`MacAgents`）都不是等待理由：需要及时看到的那台 Mac 本来就听着门铃，在线会话或 Cue 值班时还按节奏拉。

技能与规则的快照：500 个技能的快照实测约 230KB，正文另算。

在线记录复用现有续期，不加每会话心跳。

## 同步不通时说的话

同步不通（断网、要更新、等你决定）时说的话照样写下：会话与 Cue 一套规则（`Speech`），排在本机、恢复后自动发出；为什么不通只在同步那一处说（`SyncSummary`，手机上带点指过去）。

## Agent 与 Cue 的通知

- 实时活动、小组件与 App 使用同一份运行投影，Mac 发布者直接订阅 Store，不依赖界面订阅。快照过期只撤销运行证据；未知只保留已有活动，不授权新建，也不冒充完成。各 host 到期后的计数由 `CueNow.nextShownChange` 安排系统重画。
- 实时活动由 Mac 经 APNs 更新，不靠 CloudKit 唤醒；手机不拿本地旧库覆盖。令牌私有 iCloud 加密同步，中转内容不留存，密钥只在服务端。APNs 收下不证明已上屏，岛更新不证明手机资料库已同步。[部署与隐私边界](../relay/README.md)。
- ActivityKit 推送仍受网络、优先级与系统预算限制，不保证秒到；活动最多八小时，只在 App 里开启、推送只更新。`stale-date` 只标过时，不会取得新事实。依据：[ActivityKit](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)、[后台通知](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)。

## 排查与真机验证

投送请求的时间线：手机每次马上传一行"用时"（类别 `services`）；Mac 每条请求到达一行"创建后 X 秒到服务器，再 Y 秒到本机"、领取一行"创建后 X 秒"（类别 `delivery`）。X 大是发送方上传慢，Y 大是拉取慢，到达与领取的间隔大是执行器。同步的失败在类别 `sync`，门铃在类别 `relay`。

App 的日志在 subsystem 即 App 身份前缀（`Signing.xcconfig` 的 `CUEPAD_APP_ID`），CloudKit 的在 `com.apple.cloudkit`：

```bash
id=$(sed -n 's/^CUEPAD_APP_ID *= *//p' apple/App/Config/Signing.xcconfig)
log show --last 30m --info --debug --predicate "subsystem == \"$id\" OR (process == \"CuePad\" AND subsystem BEGINSWITH \"com.apple.cloudkit\")"
log stream --info --predicate 'process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit"'
```

CloudKit 日志里的错误详情是 `<private>`。

同步是否真在跑以库为准（只读复制出来看）：`syncState` 有一行 `zoneToken`，`syncRecords` 的行数随推送增长到与同步表记录数相当。真机验证：装发布版 → 设置里的 iCloud 同步先显示"正在连接 iCloud…"再变"已同步" → 几分钟内复制库检查这两张表 → 另一台设备上看到同一批项目、灵感与任务。

### 实时活动的手机取证

`xc.sh activity-log [输出.json]` 无报告时输出 `[]`；失败非零退出，保留旧导出。iCloud 只留最后上传的快照，不自动清理。

### 推送叫醒被系统结束的 App

被系统回收与用户划掉 App 不同：后者不再因后台通知被拉起，小组件不能依靠这条通路更新。已经开启并登记令牌的实时活动走独立的 ActivityKit 推送，不依赖 App 被叫醒；不把它的上屏当成手机资料库已经同步的证据。

以下需签名设备与另一台同环境设备。隔离模拟器能核对入库后的展示和 ActivityKit 内容，不能证明真实通知可达、后台预算、锁屏数据保护或低电量行为。Apple Silicon 模拟器可配 APNs 沙箱推送，仍不代表真机调度。

1. 两端在同一个环境：手机装 TestFlight 版、Mac 用正式版；或手机用 `xc.sh device` 装开发构建，Mac 那头起连开发环境的实例（`sync-bench.py` 的 real）。手机打开一次、确认设置里通知那一行正常，主屏放 Cue 小组件。
2. 打开 CuePad 后回主屏、锁屏放一会儿（不要划掉；要验冷启动，等系统回收它，或打开几个大 App 挤掉它）。
3. 在 Mac 上让 Cue 对你说一句不带选项的话（只走静默推送），再说一句带选项的（可见通知，同时叫醒 App）。
4. 不打开 App，分别核对小组件与实时活动；前者取决于 CloudKit 唤醒及 WidgetKit 刷新预算，后者应由 ActivityKit 推送换成最新计数与问题。再打开 App 核对资料库，不能用岛已更新替代这一步。
5. 小组件只在打开 App 后才变化时，查手机 `sync` 日志的拉取、账号与等待原因，也查是否真的收到唤醒；Apple 建议后台通知不要超过每小时两三条，不是固定配额。岛不更新则另查令牌记录、Mac 的 `live-activity` 日志、中转/APNs 响应与系统活动是否结束；HTTP 成功只证明 APNs 收下。
