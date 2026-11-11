# 同步参考

规则在各类型的头注释里；这里只记跨类型的取舍、实测结论与排查办法。

## 拉取节奏与门铃

别的设备的改动入库都经拉取：门铃、通知或按节奏触发。门铃在别的设备的一批改动被 iCloud 收下时经自建中转通知这台，只带"有新东西"；实时活动另经同一中转发往 APNs，不写入手机资料库。规则在 `Relay`、`RelaySecret`、`RelayCredentials`、`AppServices+Relay`，中转与协议在 `relay/`；节奏在 `SyncPoller.Cadence`，等待理由只在 `AppServices.pollingCadence` 加。

**门铃不通时 Mac 按节奏的拉取是别的设备的请求与对 Cue 说的话到达 Mac 的唯一通路，别放慢、别删**（档位在 `SyncPoller.Cadence`，兜底间隔的理由在 `Relay.silenceLimit`）。

- 实测（2026-10，正式中转、CloudKit 开发环境）：服务器收下到对方入库，只靠按节奏拉中位 1.0～1.8 秒，门铃 0.5 秒；中转停掉 2 秒内发现并退回按节奏拉，起来后 4～8 秒连回。
- 中转只有一台：`Signing.xcconfig` 的 `CUEPAD_RELAY_HOST`（部署见 `relay/README.md`），发布脚本打包前核对它活着。连真 iCloud 的实例与共享模拟云（`SharedCloud`，`SYNC_BENCH_RELAY=0` 时除外）都连它，测试里的内存替身不连；同步测量的密钥从开发容器取，房间与正式用户的不重合。
- 中转放在香港自建：Cloudflare、Vercel 的默认域名在大陆遭 DNS 污染、按 SNI 阻断。
- 密钥放在 CloudKit 私有库的加密字段，没用 iCloud 钥匙串：钥匙串另有开关、同步时机不定，两台同时生成时没有先来后到可认，会各进各的房间。没登录 iCloud 时取不到密钥，门铃不连、不重试，账号认好再连。
- Mac 只要 App 在跑就连着，手机只在前台连。每次入房先补按欠下的门铃，再拉一次；换了 iCloud 账号按新账号的密钥进新房间。
- 手机进后台的收尾（`prepareForBackground`）先把待推送传完、等门铃按完再断开中转；iPad 只退下一个窗口、别的还在前台时不收尾。
- Cue 值班是等待理由：手机对 Cue 说的一句曾 21 秒才交给它，当时 Mac 没有等待理由、一次都没拉。没开 1 秒一档：Cue 回一句本身要十几到几十秒。
- 手机的推送只为要紧的变化（`AlertSubscriptions`），灵感、任务不推；手机在后台时只靠推送与回前台的立即同步。

## 用户离开时的 Mac

用户离开后 App Nap 把 App 放进后台节流档，别的程序占满 CPU 时整个进程拿不到 CPU，按节奏的拉取能停几分钟（正式版出现过 406 秒）。两样都要，缺一样仍会饿几十秒（2026-10 加压复测：都不做拉取间隔最大 59.5 秒，只做后一样 39.8 秒，都做 2.9 秒）：

- 有等待理由期间持有系统活动（`AppServices.holdActivityWhilePolling`）：不持有时整个进程都在饿。
- 订阅重读走自己的只读连接（`CueStore` 头注释），外部提交按表叫醒（`ChangeNotification`），没人看得到主窗口时内容摘下（`MainShellWindow.parkWhileUnseen`）：持有活动后剩下的排队来自同一条队列上的活。

排查：类别 `stall`（`Logger.stall`）的 notice 落盘，记着停摆时进程晚醒多久、主线程与资料库队列各排了多久，以及一拉超过 1 秒、拉取节奏迟醒超过 1 秒（`SyncPoller`）。

## 发送

发给 Agent 与 Cue 的话经 `Workspace.speak` 入库，界面不等上传或结果；说不了的情况在 `AgentCapabilities.speakBlocked`，Pi 与终端里 Claude Code 的话按会话文件核对送达，在 `DeliveryConfirmation`。

## 附件的文件

附件记录随拉取与别的记录一起先入库，文件另走一路：传在 `FileSender`、取在 `FileFetcher`，CloudKit 那头在 `CloudDatabase+Files`，进度经 `CloudSync.fileTransfers` 给界面。记录不等文件：同一批里等附件下完才应用时，只有字的灵感曾跟着 50MB 的文件等 17 秒。

没在真环境验证到的：

- 长期操作跨重启只在开发环境验过（`SYNC_BENCH_CLOUD=real sync-bench.py fileresume`：传到四成时杀掉再起，接上、不从头传）；被系统结束、手机上的后台传完没有在真机上验。
- 空间满只在模拟云验过（`sync-bench.py filesquota`）。真 iCloud 满了时不带文件的小记录会不会也被拒没有验证到。
- 按流量计费的网络不自动取只读路径监视器，没有自动测试；自动取的其余条件由 `FileSyncTests` 覆盖。

## 说的话的链路

状态见 `DeliveryStatus`，显示与等待期限由 `Speech` 推出。排查按以下链路定位：

1. 按发送 → 本机库：写下请求，显示发送中；没到服务器不到期、可撤回。
2. 本机 → 服务器：`CloudSync.send` 马上传；同步元数据证实收下才显示已发出。
3. 服务器 → Mac：门铃或拉取（节奏与实测见「拉取节奏与门铃」）。
4. Mac → Agent：`DeliveryRequest.attachmentKeys` 统一解析附件，登记上传、取文件与回收都用它。缺附件或会话没就绪时在旁边等，不挡其他会话；到期 Mac 写回失败，手机可重发。
5. Mac → 发出方：领取与结果立即上传。派发期限（`DeliveryRequest.dispatchDeadline`）在 `DeliveryExecutor` 头注释，没回执时的显示在 `Speech`。
6. 关联与请求的保留期在 `CueStore.deleteCompletedDeliveries`。

Cue 等结果的窗口是 `Speech.cueWait`；Cue 看失败见 `cueChanges`。

## Mac 在线

每台设备自己写、别的设备只读的三张同步表，规则与写的时机在各自头注释：在不在线 `MacPresence`（`MacPresenceKeeper`）、开着哪些页 `Viewer`（`ViewerKeeper`）、有哪些 Agent 与模型 `MacAgents`（`MacAgentsRecorder`）。它们都不是等待理由：需要及时看到的那台 Mac 本来就听着门铃，在线会话或 Cue 值班时还按节奏拉（「拉取节奏与门铃」）。

技能与规则也是每台 Mac 自己写：一条快照只有元数据（`AgentLibrary`），每份文件的正文各一条（`LibraryFileText`），Mac 每次重读只写内容变了的、删掉不在了的，手机打开文件页读本地已同步来的那条。不把正文塞进快照：几百个技能就超过单条记录 1MB 的上限（500 个技能的快照实测约 230KB，正文另算）。理由与先到后到的读法在两者的头注释。

运行报告通过系统 boot 与所属 Mac 的在线期限关联；App 重开不换系统 boot，摘要回填不刷新运行确认。没有当前证据时保留最后报告与任务历史，但不继续声称正在运行，也不冒充全部完成。异常断电仍需等待在线期限失效，不是瞬时探活。

在线记录复用现有续期，不加每会话心跳。普通通知只订阅要紧变化（`AlertSubscriptions`）；实时活动的有效期限参与内容比较，需要续期时会有额外活动更新，不能称为零流量。

## 失败与重试

- 没在真网络上确认的：断网时 CloudKit 整批抛的是 `partialFailure` 包着 -1009，还是 URL 错误原样；区忙带不带 `retryAfterSeconds`。归类（`SyncFault`）对这几种包法给同一个结论，所以不影响行为。

## 最低对端版本

门槛怎么抬、旧端怎么表现在 `PeerFloor` 头注释；旧端暂停收发但可写，故按 [release.md](release.md)「发版顺序」先发 iOS。库起点 `Schema.baseVersion` 怎么定见它的注释。

同步不通（断网、要更新、等你决定）时说的话照样写下：会话与 Cue 一套规则（`Speech`），排在本机、恢复后自动发出；为什么不通只在同步那一处说（`SyncSummary`，手机上带点指过去）。

## 自己的回声不是冲突

回声不留冲突副本；关联字段怎么排序见 `SessionBindingRevision` 头注释，正文仍按记录版本合并。

结束请求、来源与重启后“未知”的规则在 `UnusedSessions` 头注释。

## Agent 与 Cue 的通知

到不到你只有 `CueStore.reaches` 一处，他此刻在哪台设备前只按最近一次来到哪台（`Viewer`）；进了等你的事手机总会被叫醒，到不到你只定出不出通知（`CuePush`、`AlertPush`）。手机锁屏通知怎么由服务端生成在 `AlertSubscriptions`，两端怎么发在 `AlertCenter`。代码里没写的取舍：

- 实时活动、小组件与 App 使用同一份运行投影，Mac 发布者直接订阅 Store，不依赖界面订阅。快照过期只撤销运行证据；未知只保留已有活动，不授权新建，也不冒充完成。各 host 到期后的计数由 `CueNow.nextShownChange` 安排系统重画。
- 实时活动由 Mac 经 APNs 更新，不靠 CloudKit 唤醒；手机不拿本地旧库覆盖。令牌私有 iCloud 加密同步，中转内容不留存，密钥只在服务端。APNs 收下不证明已上屏，岛更新不证明手机资料库已同步。[部署与隐私边界](../relay/README.md)。
- ActivityKit 推送仍受网络、优先级与系统预算限制，不保证秒到；活动最多八小时，本次不远程开启。`stale-date` 只标过时，不会取得新事实。依据：[ActivityKit](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)、[后台通知](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)。
- Mac 提示音装进 ~/Library/Sounds（`AlertSounds`），卸载 App 后会留下，也会出现在系统设置的提示音列表里。
- 改订阅的定义（谓词、选项、通知文案 key）等于改 schema，见 [release.md](release.md)。

## 排查与真机验证

投送请求的时间线：手机每次马上传一行"用时"（类别 `services`）；Mac 每条请求到达一行"创建后 X 秒到服务器，再 Y 秒到本机"、领取一行"创建后 X 秒"（类别 `delivery`）。X 大是发送方上传慢，Y 大是拉取慢，到达与领取的间隔大是执行器。同步的失败在类别 `sync` 按段记：会自己恢复的（连不上、被限流、区忙、账号）进入等待一条（归类、等多久、"CloudKit 7 requestRateLimited：原话"）、恢复一条，其间每次重试不记；意料之外的进问题列表时记一条 error。门铃（类别 `relay`）同样只记断了、连回来各一条。

App 的日志在 subsystem 即 App 身份前缀（`Signing.xcconfig` 的 `CUEPAD_APP_ID`），CloudKit 的在 `com.apple.cloudkit`：

```bash
id=$(sed -n 's/^CUEPAD_APP_ID *= *//p' apple/App/Config/Signing.xcconfig)
log show --last 30m --info --debug --predicate "subsystem == \"$id\" OR (process == \"CuePad\" AND subsystem BEGINSWITH \"com.apple.cloudkit\")"
log stream --info --predicate 'process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit"'
```

CloudKit 日志里的错误详情是 `<private>`。要复现：拿用户库的副本、清掉 `syncState`，在带生产签名的最小程序里用真实同步代码跑一遍、读问题列表——它会真的上传副本里的待推送记录，只在确认副本内容就是用户本机那份时做。

同步是否真在跑以库为准（只读复制出来看）：`syncState` 有一行 `zoneToken`，`syncRecords` 的行数随推送增长到与同步表记录数相当。真机验证：装发布版 → 设置里的 iCloud 同步先显示"正在连接 iCloud…"再变"已同步" → 几分钟内复制库检查这两张表 → 另一台设备上看到同一批项目、灵感与任务。

验证生产环境的订阅能否创建：用 Developer ID 描述文件签名、带 production 容器权限的最小 Mac 程序保存订阅，打印完整的 CKError（看 `description`，`localizedDescription` 会丢掉服务端的说明）。开发环境的 Mac 描述文件按 Provisioning UDID 登记设备，不是 Hardware UUID。

### 实时活动的手机取证

`xc.sh activity-log <输出.json>` 签隔离 Mac 副本，在 AppDelegate 与库启动前只读生产私有区，不重启正式版。无报告成功输出 `[]`；失败非零退出，保留旧导出。

取证与地址独立，按账号隔离。写本地后异步上传，失败不改活动决策、不续后台时间。本地写入时保留近七天最多 96 条；iCloud 只留最后上传快照，不自动清理。不记正文、原始令牌或完整错误。`contentObserved`、`sourceAt` 与 `contentTag` 只表示 App 观察，不证明屏幕展示。隔离演示加 `-CuePadActivityDiagnostics YES`。跨网络、后台和真实撤销待 TestFlight 验收。

### 推送叫醒被系统结束的 App

CloudKit 推送先于同步启动到达时，拉取要等同步开始（`CloudSync.syncNow`），小组件与角标更新完再交还系统（`IOSAppDelegate`）。被系统回收与用户划掉 App 不同：后者不再因后台通知被拉起，小组件不能依靠这条通路更新。已经开启并登记令牌的实时活动走独立的 ActivityKit 推送，不依赖 App 被叫醒；不把它的上屏当成手机资料库已经同步的证据。

以下需签名设备与另一台同环境设备。隔离模拟器能核对入库后的展示和 ActivityKit 内容，不能证明真实通知可达、后台预算、锁屏数据保护或低电量行为。Apple Silicon 模拟器可配 APNs 沙箱推送，仍不代表真机调度。

1. 两端在同一个环境：生产订阅部署之后，手机装 TestFlight 版、Mac 用正式版；之前用 `xc.sh device` 装的开发构建，Mac 那头起连开发环境的实例（见 [perf.md](perf.md)「同步测量」）。手机打开一次、确认设置里通知那一行正常，主屏放 Cue 小组件。
2. 打开 CuePad 后回主屏、锁屏放一会儿（不要划掉；要验冷启动，等系统回收它，或打开几个大 App 挤掉它）。
3. 在 Mac 上让 Cue 对你说一句不带选项的话（只走静默推送），再说一句带选项的（可见通知，同时叫醒 App）。
4. 不打开 App，分别核对小组件与实时活动；前者取决于 CloudKit 唤醒及 WidgetKit 刷新预算，后者应由 ActivityKit 推送换成最新计数与问题。再打开 App 核对资料库，不能用岛已更新替代这一步。
5. 小组件只在打开 App 后才变化时，查手机 `sync` 日志的拉取、账号与等待原因，也查是否真的收到唤醒；Apple 建议后台通知不要超过每小时两三条，不是固定配额。岛不更新则另查令牌记录、Mac 的 `live-activity` 日志、中转/APNs 响应与系统活动是否结束；HTTP 成功只证明 APNs 收下。
