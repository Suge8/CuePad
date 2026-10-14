# 同步参考

引擎、协调器、拉取器、上传去重、订阅的实现与理由写在各自文件的头注释里（`CueSync/`、`AppServices+Sync.swift`、`PiStateRecorder.swift`）。这里只补代码看不出的：拉取节奏的实测结论、发送的约定、通知的取舍、排查与真机验证。

## 拉取节奏

节奏与理由见 `AppServices.pollingCadence` 的注释。**2 秒主动拉取（`ZoneChangePuller`）是别的设备写来的请求到达 Mac 的主通路，不是推送之外的兜底，别放慢、别删。**

实测（2026-10-12 00:06–00:13，手机发 18 条请求）：Mac 这 7 分钟一次 CloudKit 推送都没收到，18 条全靠主动拉取到达，服务器到 Mac 0.44–2.67 秒、中位约 1.1 秒；Mac 的 CuePad 进程日志里 4 小时只有 7 次 "received push via PushKit"，与请求时间对不上。推送在这台 Mac 上不能当通路（只测了这一台 Mac，别的 Mac 与网络环境没测过）；改它之前要先有新的实测，不要凭"每天四万多次请求太多"去放慢。

Mac 现在不注册推送（见「Agent 与 Cue 的通知」），所以凡是 Mac 要及时看到别的设备写来的东西，都得是拉取节奏里的一个等待理由：除了在线会话与没结果的投送请求，还有 Cue 在这台值班（等你在手机上对 Cue 说的话、等别的 Mac 接管）。理由只加在 `pollingCadence` 一处；它等的表同时进 `ZoneChangePuller.awaitedTables`（只管第一次取令牌时补取，之后的拉取本来就带回全部表）。其余改动（灵感、任务等）没有理由时靠切到前台、唤醒时的立即同步与引擎自己的调度。

立即上传（`CloudSync.sendNow`：手机写出的请求、Mac 写回的结果）与主动拉取对称，也不经 CKSyncEngine：引擎的操作是串行的，显式的 `sendChanges` 会排在正在进行的拉取（含大附件下载）、上传与退避之后。起因：2026-10-12 手机发的两条请求（创建相隔 2 分钟）在 Mac 上同一次拉取才到，Mac 在那次拉取结束后 0.09 秒就执行了，延迟在手机上传这一段。引擎排队是最符合的原因，没有手机日志佐证，未确认；确认靠下面的 `delivery` 日志。

## 发送

- 发给 Pi 只有投送请求一种记录。Mac 上发给 Pi 会话（回复框、灵感与任务的发送、菜单栏稿纸）也是写一条指定本机 `hostID` 的投送请求，由本机执行器与手机发来的请求同一流程执行，发起的界面等结果再提示。发给别的 Mac 上在线的会话（Mac 与手机的"发给 Agent"目标是同一批：所有 Mac 上在线的会话，`HandOffTargets`）同样写请求，`hostID` 是会话所在的那台 Mac，写出后立即上传、不等结果，进度和"没能送达"看会话行。
- 直接发送而会话正忙时不写请求，先问"马上说"还是"等它做完再说"。
- 失败原因一律读 `DeliveryRequest.failure`，界面不另写兜底句。
- 订阅额度（`AccountQuota`）只有 Mac 写。手机上的额度视图打开、数据陈旧时写一条 `quota` 请求给最近写过额度的那台 Mac，不等结果、失败不提示：新值随同步回来，查不到就照旧显示上次的值与更新时间。节流与 Mac 本机同一套（`AccountQuotas`）。
- 方式（`DeliveryMode`）与各自的约定见 `DeliveryRequest.swift` 与 `MacExecutor.swift` 的注释；命令与设置类请求（斜杠命令、会话设置、作答、结束、停止、绑定文件夹）不是说的话，不写发送记录。

## 自己的回声不是冲突

本机上传的版本会从主动拉取、引擎拉取、被拒时附的服务器版本回到本机，而用户连续编辑时本机往往已有更新的版本。回声当成并发编辑，每次都会留下一张冲突副本（正文是旧版本、没有上级，堆在项目页"最近"里；2026-10-12 一台 Mac 上 4 分钟 17 张）。认回声分两处，都在 `CueStore.applyVersion`，都存在库里（不限版本数，重启后仍有效）：上传结果落账前回来的，本机构造记录时已把这一版整行记进 `syncSent`（结果回来时也按它记账，是“已交出去、还没落账的版本”唯一的一份记录），回来的版本与其中某条修改时间完全相同，就只按“服务器收下了它”记账（记下新的版本标签）；落账后回来的，远端修改时间不晚于 `syncRecords.pushedModifiedAt`，本机有更新的编辑时直接忽略。落账时清掉 `syncSent` 里不晚于推送时间的条目。被拒时附的服务器版本就是刚传的这一版（上一次的结果丢了）走前一处。前提：别的设备的并发编辑晚于本机上次同步的版本（时钟大致对准）；并发编辑与本机交出去的某一版落在同一毫秒会被当成回声。别的设备的并发编辑仍走冲突规则保留副本。

## Agent 与 Cue 的通知

- "要不要提示"只有一条规则 `PiAlert.entering`：Mac 写会话状态时置位手机推送标志，两端读同步来的在线会话认出转换（`SessionAlertTracker`），都用它。通知代理、权限与点开的路由两端一份（`AlertCenter`）。
- iPhone：锁屏通知由 CloudKit 查询订阅在服务端生成，不靠 App 在后台运行。Pi 会话状态记录带明文可查询的 `notify` 标志，是一次性事件标志，只存在于未上传的版本上（理由与规则见 `PiStateRecorder` 与 `PiAlerts.swift`）；Cue 的消息同样带 `notify`，只由 Cue 值班的那台 Mac 置位（`CueService`），上传即清。取舍：通知反映服务端收到记录那一刻的状态，标志在上传前被状态已前进的写入取代就不送出；状态记录不是事件日志，要保证每个事件都送达需要单独的追加式通知事件记录，那是另一种设计。前台不展示 Agent 的系统通知，提示是 App 内横幅（读同步来的会话状态，不依赖推送是否到达）。
- Mac 不注册远程通知、没有推送权限：账号级订阅的推送一到 Mac，CuePad 不在前台时由系统直接展示，设置里的开关与提示音管不到；同步到达本来也不靠推送（见「拉取节奏」）。Mac 的提示都是本机发的本地通知：Agent 的不分会话在本机还是别的 Mac，同一条路（`LiveSessions` → `SessionAlertTracker`，本次运行第一次读到的只记基线）；Cue 的由值班的 Mac 读库（`CueService.followNotifications`）。你在不在看只有一处（`Workspace.isWatching`）：正看着那一页什么都不发，其余前台后台都是系统横幅加声音（macOS 27 实测前台回复里带 `.sound` 系统就会弹横幅，所以不另出窗口里的提示条），免打扰只认系统的专注模式。打开会话时撤掉它那一组已送达的通知。"等你"只算不由 Cue 跟进的会话（`PiSessionState.asksYou`），通知、手机推送标志与"等你 N"、Dock 角标同一条规则。
- Mac 的提示音：通知中心只在 ~/Library/Sounds 与系统声音目录里找声音，不看 App 包；一个声音名找不到过一次，之后装上了也播兜底音。所以先把选中的那段装进去再发（`AlertSounds`）。这几个文件卸载 App 后会留下，也会出现在系统设置的提示音列表里。
- 改订阅的定义（谓词、选项、通知文案 key）等于改 schema，见 [release.md](release.md)。

## 排查与真机验证

投送请求的时间线：手机每次立即上传一行"用时"（类别 `services`）；Mac 每条请求到达一行"创建后 X 秒到服务器，再 Y 秒到本机"、领取一行"创建后 X 秒"（类别 `delivery`）。X 大是发送方上传慢，Y 大是拉取慢，到达与领取的间隔大是执行器。立即上传被服务器拒绝或整个请求失败时，`delivery` 里有一行带错误码与服务器说明（`SyncCoordinator.sendNow`）。

立即上传与引擎可能同时传同一条记录（引擎刚把上一版传上去、结果还在路上），本机带的版本标签就是旧的，被服务器以 `serverRecordChanged` 拒绝：`sendNow` 记下服务器的版本后马上带新标签重传，不回落引擎（回落要多等一轮调度）；两边的结果乱序回来时，旧版的结果不会把版本标签退回去（`markPushed`）。

App 的日志在 subsystem `com.sugeh.cuepad`（类别 `services`、`launch`、`shutdown`、`pi-history`、`sync`）；CloudKit 与 CKSyncEngine 的日志在 `com.apple.cloudkit`：

```bash
log show --last 30m --info --debug --predicate 'subsystem == "com.sugeh.cuepad" OR (process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit")'
log stream --info --predicate 'process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit"'
```

引擎日志里的错误详情是 `<private>`，看不到原因。要复现：拿用户库的副本、清掉引擎状态，在带生产签名的最小程序里用真实同步代码跑一遍、读问题列表——它会真的上传副本里的待推送记录，只在确认副本内容就是用户本机那份时做。

同步是否真在跑，以库为准（只读复制出来看，不碰用户的库）：`syncState` 有一行 `engine`，`syncRecords` 的行数随推送增长到与同步表记录数相当。真机验证：装发布版 → 打开设置里的 iCloud 同步那一行，先显示"正在连接 iCloud…"再变"已同步" → 几分钟内复制库检查上面两张表 → 另一台设备上能看到同一批项目、灵感与任务。

验证生产环境的订阅能否创建：用 Developer ID 描述文件签名、带 production 容器权限的最小 Mac 程序保存订阅，打印完整的 CKError（看 `description`，`localizedDescription` 会丢掉服务端的说明）；开发环境的 Mac 描述文件按 Provisioning UDID 登记设备，不是 Hardware UUID。
