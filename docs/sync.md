# 同步参考

拉取器、发送者、协调器、订阅的实现与理由写在各自文件的头注释里（`CueSync/`、`AppServices+Sync.swift`、`PiStateRecorder.swift`）。这里只补代码看不出的：同步通路的取舍、拉取节奏的实测结论、发送的约定、通知的取舍、排查与真机验证。

## 一条通路

拉与推都是自己的同步循环（`CloudSync`），不用 CKSyncEngine：macOS 27.2 实测它的手动 `fetchChanges()` 只在全新状态的第一次真发请求，之后没收到推送就原地返回（日志 "no zone IDs needing to be fetched"，连库级变化查询都不发），有没有推送权限、限定区、带旧状态重启都一样；Mac 不收推送，用它就拉不到任何东西。它的待办队列又是库里推导的待推送之外的第二份事实。

- 拉（`ZonePuller`）：同步区令牌只有库里一份。没有令牌时按版本对一遍账（只带 `modifiedAt` 翻区，再取较新的整条，推送过而服务器没有的按别处删掉），之后只从令牌增量拉；冷启动不翻全区。
- 推（`RecordSender`）：库里推导的待推送是唯一队列，同一时刻只有一批在路上，所以没有两路上传互相以版本冲突拒绝，结果也按发出的先后回来。"马上传这几条"（`upload`）只是让它们排在最前。
- 手机建一个同步区有变化的静默推送订阅，收到推送（含前台的 Agent、Cue 通知）就拉一次；Mac 不注册推送，靠等待理由驱动的拉取。

## 拉取节奏

节奏与理由见 `SyncPoller.Cadence.mac`、`.phone` 的注释。**Mac 的 2 秒拉取是别的设备写来的请求与对 Cue 说的话到达 Mac 的唯一通路，别放慢、别删。**

实测（2026-10-12 00:06–00:13，手机发 18 条请求）：服务器到 Mac 0.44–2.67 秒、中位约 1.1 秒，全靠拉取到达。改节奏之前要先有新的实测，不要凭"每天四万多次请求太多"去放慢。

Cue 值班也是在等：2026-10-14 手机对 Cue 说的一句 21 秒才交给它（Mac 没有等待理由，一次都没拉）。之后 Cue 值班和别的理由同一档每 2 秒拉；间隔从上一次开拉算起，平均约 1 秒、最坏约 2 秒到。没开 1 秒一档：Cue 回一句本身要十几到几十秒。

凡是一台设备要及时看到别的设备写来的东西，都得是 `pollingCadence` 里的一个等待理由（Mac：在线会话、没结果的投送请求、Cue 值班；手机：没结果的投送请求、正看着 Agent 页、会话近况或 Cue 页）。理由只加在这一处。其余改动（灵感、任务等）靠切到前台、唤醒时的立即同步，手机另有推送。

"立即同步"（下拉刷新、设置里的按钮、切到前台、唤醒）只是立即拉一次，待推送顺带发出去、不等；界面最多等 5 秒（`AppServices.syncNow`）。手机进入后台时把待推送发完再挂起。

## 发送

- 发给 Pi 只有投送请求一种记录。Mac 上发给 Pi 会话（回复框、灵感与任务的发送、菜单栏稿纸）也是写一条指定本机 `hostID` 的投送请求，由本机执行器与手机发来的请求同一流程执行，发起的界面等结果再提示。发给别的 Mac 上在线的会话（Mac 与手机的"发给 Agent"目标是同一批：所有 Mac 上在线的会话，`HandOffTargets`）同样写请求，`hostID` 是会话所在的那台 Mac，写出后立即上传、不等结果，进度和"没能送达"看会话行。
- 直接发送而会话正忙时不写请求，先问"马上说"还是"等它做完再说"。
- 失败原因一律读 `DeliveryRequest.failure`，界面不另写兜底句。
- 订阅额度（`AccountQuota`）只有 Mac 写。手机上的额度视图打开、数据陈旧时写一条 `quota` 请求给最近写过额度的那台 Mac，不等结果、失败不提示：新值随同步回来，查不到就照旧显示上次的值与更新时间。节流与 Mac 本机同一套（`AccountQuotas`）。
- 方式（`DeliveryMode`）与各自的约定见 `DeliveryRequest.swift` 与 `MacExecutor.swift` 的注释；命令与设置类请求（斜杠命令、会话设置、作答、结束、停止、绑定文件夹）不是说的话，不写发送记录。

## 自己的回声不是冲突

本机上传的版本会经拉取或被拒时附的服务器版本回到本机，而用户连续编辑时本机往往已有更新的版本。回声当成并发编辑，每次都会留下一张冲突副本（2026-10-12 一台 Mac 上 4 分钟 17 张，当时有两路上传）。回声按 `syncRecords` 的两个修改时间认（`CueStore.applyVersion`）：不晚于服务器收下的那一版（`pushedModifiedAt`）且本机有更新的编辑时直接忽略；等于交出去而结果没回到本机的那一版（`sentModifiedAt`，崩溃或回包丢失）时按服务器收下记账。同一时刻只有一批上传在路上，所以每条记录记一个交出去的时间就够。前提：别的设备的并发编辑晚于本机上次同步的版本（时钟大致对准），且不与本机交出去的那一版落在同一毫秒。

## Agent 与 Cue 的通知

- "要不要提示"只有一条规则 `PiAlert.entering`：Mac 写会话状态时置位手机推送标志，两端读同步来的在线会话认出转换（`SessionAlertTracker`），都用它。通知代理、权限与点开的路由两端一份（`AlertCenter`）。
- iPhone：锁屏通知由 CloudKit 查询订阅在服务端生成，不靠 App 在后台运行。Pi 会话状态记录带明文可查询的 `notify` 标志，是一次性事件标志，只存在于未上传的版本上（理由与规则见 `PiStateRecorder` 与 `PiAlerts.swift`）；Cue 的消息同样带 `notify`，只由 Cue 值班的那台 Mac 置位（`CueService`），上传即清。取舍：通知反映服务端收到记录那一刻的状态，标志在上传前被状态已前进的写入取代就不送出；状态记录不是事件日志，要保证每个事件都送达需要单独的追加式通知事件记录，那是另一种设计。前台不展示 Agent 的系统通知，提示是 App 内横幅（读同步来的会话状态，不依赖推送是否到达）。
- Mac 不注册远程通知、没有推送权限：账号级订阅的推送一到 Mac，CuePad 不在前台时由系统直接展示，设置里的开关与提示音管不到；同步到达本来也不靠推送（见「拉取节奏」）。
- 手机前台收到 Agent 或 Cue 的通知、后台收到同步区变化的静默推送，都立即拉一次（`AlertCenter.pushed`、`IOSAppDelegate`），不等切一次后台。Mac 的提示都是本机发的本地通知：Agent 的不分会话在本机还是别的 Mac，同一条路（`LiveSessions` → `SessionAlertTracker`，本次运行第一次读到的只记基线）；Cue 的由值班的 Mac 读库（`CueService.followNotifications`）。你在不在看只有一处（`Workspace.isWatching`）：正看着那一页什么都不发，其余前台后台都是系统横幅加声音（macOS 27 实测前台回复里带 `.sound` 系统就会弹横幅，所以不另出窗口里的提示条），免打扰只认系统的专注模式。打开会话时撤掉它那一组已送达的通知。"等你"只算不由 Cue 跟进的会话（`PiSessionState.asksYou`），通知、手机推送标志与"等你 N"、Dock 角标同一条规则。
- Mac 的提示音：通知中心只在 ~/Library/Sounds 与系统声音目录里找声音，不看 App 包；一个声音名找不到过一次，之后装上了也播兜底音。所以先把选中的那段装进去再发（`AlertSounds`）。这几个文件卸载 App 后会留下，也会出现在系统设置的提示音列表里。
- 改订阅的定义（谓词、选项、通知文案 key）等于改 schema，见 [release.md](release.md)。

## 排查与真机验证

投送请求的时间线：手机每次马上传一行"用时"（类别 `services`）；Mac 每条请求到达一行"创建后 X 秒到服务器，再 Y 秒到本机"、领取一行"创建后 X 秒"（类别 `delivery`）。X 大是发送方上传慢，Y 大是拉取慢，到达与领取的间隔大是执行器。整批上传失败与拉取失败在类别 `sync`，带错误码与服务器说明。

App 的日志在 subsystem `com.sugeh.cuepad`（类别 `services`、`launch`、`shutdown`、`pi-history`、`sync`）；CloudKit 的日志在 `com.apple.cloudkit`：

```bash
log show --last 30m --info --debug --predicate 'subsystem == "com.sugeh.cuepad" OR (process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit")'
log stream --info --predicate 'process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit"'
```

CloudKit 日志里的错误详情是 `<private>`，看不到原因。要复现：拿用户库的副本、清掉 `syncState`，在带生产签名的最小程序里用真实同步代码跑一遍、读问题列表——它会真的上传副本里的待推送记录，只在确认副本内容就是用户本机那份时做。

同步是否真在跑，以库为准（只读复制出来看，不碰用户的库）：`syncState` 有一行 `zoneToken`，`syncRecords` 的行数随推送增长到与同步表记录数相当。真机验证：装发布版 → 打开设置里的 iCloud 同步那一行，先显示"正在连接 iCloud…"再变"已同步" → 几分钟内复制库检查上面两张表 → 另一台设备上能看到同一批项目、灵感与任务。

验证生产环境的订阅能否创建：用 Developer ID 描述文件签名、带 production 容器权限的最小 Mac 程序保存订阅，打印完整的 CKError（看 `description`，`localizedDescription` 会丢掉服务端的说明）；开发环境的 Mac 描述文件按 Provisioning UDID 登记设备，不是 Hardware UUID。
