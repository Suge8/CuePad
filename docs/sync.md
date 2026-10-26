# 同步参考

同步通路、拉取、发送与通知的规则和理由写在各自类型的头注释里：通路、冷启动与为什么不用 CKSyncEngine 在 `CloudSync`，拉、推在 `ZonePuller`、`RecordSender`，失败怎么归类、怎么重试在 `SyncFault`、`SyncCoordinator+Hold`，等待理由与立即同步在 `AppServices+Sync.swift`，说的话到哪了在 `Speech`。这里只补代码里没有的：实测结论、跨设备的取舍、排查与真机验证。

## 拉取节奏与门铃

别的设备的改动到本机只有两条路：门铃叫这台拉一次，或按节奏拉。门铃（实时层）在别的设备的一批改动被 iCloud 收下时经自建中转通知这台，中转只转发"有新东西"，数据只在 iCloud。规则在 `Relay`（连接、重连、心跳、欠一次、进后台前断开、后台短连）、`RelaySecret`（密钥，经 `CloudSync.relaySecret` 取）、`RelayCredentials`（房间号与签名）、`AppServices+Relay`（何时连、按与听），中转与协议在 `relay/`；节奏在 `SyncPoller.Cadence`，等待理由只在 `AppServices.pollingCadence` 加。

**门铃不通时（连不上中转、心跳判断断了），Mac 的 2 秒拉取是别的设备写来的请求与对 Cue 说的话到达 Mac 的唯一通路，别放慢、别删。** 门铃通着时按节奏的拉取降为 15 秒一次的兜底（理由在 `Relay.silenceLimit`）；门铃断了当场换回快档、立即拉一次。

中转只有一台：`Signing.xcconfig` 的 `CUEPAD_RELAY_HOST`（正式版是 `relay.cue-pad.com`，部署在 hk-relay，见 `relay/README.md`），经 Info.plist 给 App，发布脚本打包前核对它活着（`check_relay`）。连真 iCloud 的实例都连它，测试与调试画面的替身云不连；同步测量的隔离实例走 CloudKit 开发环境，密钥从开发容器取，房间与正式用户的不会重合。

实测（2026-10-25 23:20，正式中转，CloudKit 开发环境，同一台 Mac 两个实例，机器 load 几十到几百，测法是研究分支 research/relay-on-measure 的 sync-measure.py）：

| 怎么到 | 服务器收下 → 对方入库，中位 / p95（秒） |
|---|---|
| 只靠按节奏拉（Mac 2 秒、手机看着时 3 秒） | 1.0–1.8 / 1.5–2.9 |
| 门铃（Mac→手机、手机→Mac 两个方向） | 0.47–0.51 / 0.58–0.87 |

- 门铃这一路的中位：服务器收下到本机得知收下 0.21 秒，按铃 0.01 秒内，中转转给对方 0.11 秒，对方拉到入库 0.15–0.17 秒。
- 中转停掉（进程退出，停 32 秒）：2 秒内发现，期间按 2 秒拉，中位 1.6 秒到；重连的退避上限是 15 秒（`Backoff.waitingCap`），中转起来后 4–8 秒连回去，之后中位 0.45 秒。
- 中转冻住（连接还在、不再回应，开发中转上测）：心跳 11–14 秒判断断开，这段里到的一条 8 秒才到；判断断开后按 2 秒拉，中位 0.95 秒。
- 门铃通着、谁都不写的一分钟，在等的 Mac 拉 29 次（不降档）→ 4 次。
- Mac 只要 App 在跑就连着：不在等的 Mac 原本要到下一次被叫醒才拉到手机改的灵感、任务，现在一响就拉（0.40–0.82 秒）。手机只在前台连。门铃引起的拉取经 `pull`，与按节奏的拉取、立即同步合并，同步还在启动时先等启动。
- 每次入房先补按欠下的门铃（本机的改动被收下时门铃没通），再拉一次（补上没连着时听不到的）；换了 iCloud 账号就按新账号的密钥进新房间。
- 手机进后台的收尾（`prepareForBackground`，在后台任务里）先把待推送传完、等门铃按完再断开中转，传完之前就回了前台的不断；实测按铃后 2 毫秒内断开，对方都听到了。iPad 只退下一个窗口、别的还在前台时不收尾。
- 心跳、收门铃与入房那一拉同时开始；中转空闲时自己发 ping（Bun 默认），客户端只回 pong 也不会被 20 秒的空闲上限断开（本机实测 50 秒仍连着）。
- Cue 值班是等待理由：2026-10-14 手机对 Cue 说的一句 21 秒才交给它，当时 Mac 没有等待理由、一次都没拉。没开 1 秒一档：Cue 回一句本身要十几到几十秒。
- 手机的推送只为要紧的变化（`AlertSubscriptions`），灵感、任务不推；手机在后台时只靠推送与回前台的立即同步。
- 中转放在香港自建：Cloudflare、Vercel 的默认域名在大陆遭 DNS 污染、按 SNI 阻断，直连用不了。
- 密钥放在 CloudKit 私有库的加密字段，没用 iCloud 钥匙串：钥匙串另有开关、同步时机不定，两台同时生成时没有先来后到可认，会各进各的房间。
- 没登录 iCloud 时取不到密钥，门铃一直不连、不重试，账号认好再连。

## 用户离开时的 Mac

用户离开后 App Nap 把 App 放进后台节流档，别的程序占满 CPU 时整个进程拿不到 CPU，按节奏的拉取能停几分钟（2026-10-24 正式版最长 406 秒）。所以有等待理由期间持有系统活动（`AppServices.holdActivityWhilePolling`）。

2026-10-25 复测条件：真实库副本、替身云、6 个会话加命令行在写、30 个忙循环加压 60 秒。

| 构建 | 拉取间隔最大 | 读令牌等待最大 |
|---|---|---|
| 改前 | 59.5 秒（加压的一分钟只开拉 1 次） | 39 秒 |
| 只拆开重读、不持有活动 | 39.8 秒 | 24 秒 |
| 全部改动 | 2.9 秒；60 个忙循环时 2.4 秒 | 0.5 秒 |

两样都要：

- 不持有活动，拆开重读也救不了：整个进程都在饿。
- 持有活动后，剩下的排队来自同一条队列上的活。所以订阅重读走自己的只读连接（`CueStore` 头注释）。外部提交按表叫醒（`ChangeNotification`）。没人看得到主窗口时内容摘下（`MainShellWindow.parkWhileUnseen`，锁屏、6 个会话在写时主线程忙碌从 72% 降到 4%）。

排查：类别 `stall`（`Logger.stall`）的 notice 落盘，记着停摆时进程晚醒多久、主线程与资料库队列各排了多久，以及一拉超过 1 秒、拉取节奏迟醒超过 1 秒（`SyncPoller`）。

## 发送

- 所有发给 Agent 与 Cue 的话都经 `Workspace.speak` 写一条投送请求或 Cue 消息，界面不等上传与结果（`lint.sh` 查）。方式与各自的约定在 `DeliveryMode`，执行与重试在 `DeliveryExecutor`、`MacExecutor`。
- 终端里的 Claude Code 在跑时说不了，规则只在 `AgentCapabilities.speakBlocked`。

## 说的话的链路

状态与时限只在 `Speech`，每句只看自己的证据：服务器收下过没有读同步元数据（`CueStore+Speech`），不另存；全局同步状态一时不通只影响还没传出去的话的时限起点，不让已发出的话变红。一句话从按发送到本机看到回执走的通路，排查慢在哪一段时对照：

1. 按发送 → 本机库：先清空输入框，再写一条记录（毫秒级）。气泡是发送中。
2. 本机 → 服务器：马上传（`CloudSync.send`），收下即已发出；满 `Speech.sendLimit` 还没传上去是没能送达（实测与取值理由在它的注释里）。
3. 服务器 → 接收的 Mac：门铃或按节奏的拉取（节奏与实测见「拉取节奏与门铃」）。
4. Mac 交给 Agent 或 Cue：0.2 秒内；写回结果、交给 Cue 后马上传，执行超过半秒的先传领取（`DeliveryExecutor.claimGrace`）。Cue 回你的话同样马上传：由发送者从提交里认出来（`RecordSender.speak`），不靠写的人叫。
5. 服务器 → 发出方：门铃或按节奏的拉取（手机有在等回执的话时在等，见「拉取节奏与门铃」），另有推送。回执到了是已送达；已发出满 `Speech.receiptLimit`（同步不通时不计）没回执是 Mac 迟迟没收下。
6. 进对话：Mac 读到会话文件里带请求标识的那条，在同一个事务里收走请求，气泡由对话里那条接替（`PiChat.outgoing`）。

Cue 说话的工具等结果至多 `Speech.cueWait`；没告诉它的失败作为"[发送失败]"写进它下一轮的变化并叫醒它（`CueTools`、`cueToldAt`）。

## Mac 在线

每台设备自己写、别的设备只读的三张同步表，规则与写的时机在各自头注释：在不在线 `MacPresence`（`MacPresenceKeeper`）、开着哪一页 `Viewer`（`ViewerKeeper`）、有哪些 Agent 与模型 `MacAgents`（`MacAgentsRecorder`）。它们都不是等待理由：需要及时看到的那台 Mac 本来就听着门铃，在线会话或 Cue 值班时还按节奏拉（「拉取节奏与门铃」）。

推送的取舍：在线记录的续期不给手机推送，手机只订阅要紧的变化（理由与实测在 `AlertSubscriptions` 头注释）。

## 失败与重试

- 复测失败路径用 `research/sync-faults` 分支的故障探针（内存替身注入延迟与错误，Kit 与 App 两层，不合并）：叠到改动上跑 `xc.sh test kit -only-testing:CueSyncTests/SyncFaultProbeTests`、`xc.sh test mac|ios -only-testing:CuePadTests/SyncFaultProbeTests`。探针里挂得比 `RequestLimits.request` 久的数据库请求要按 CloudKit 的空闲超时到点失败，才和真机一致。
- 没在真网络上确认的：断网时 CloudKit 整批抛的是 `partialFailure` 包着 -1009，还是 URL 错误原样；区忙带不带 `retryAfterSeconds`。归类（`SyncFault`）对这几种包法给同一个结论，所以不影响行为。

## 最低对端版本

跨版本兼容只有一个门槛，规则在 `PeerFloor`：记录格式换到旧版读不懂时上调 `Schema.peerFloor`，同一个改动里删掉给更早设备留的兼容。它不是本机库的起点 `Schema.baseVersion`：那个要等用户的库都升过才挪。门槛只拦得住认它的版本（2026-10 起），所有设备都升到这之后的版本前，不能凭它删兼容。

## 自己的回声不是冲突

本机上传的版本会经拉取回到本机，当成并发编辑就每次留一张冲突副本（2026-10-12 一台 Mac 上 4 分钟 17 张，当时有两路上传）。认法在 `CueStore` 的 `applyVersion`。前提：别的设备的并发编辑晚于本机上次同步的版本（时钟大致对准）。本机同一行的新版本一定比旧的大（`CueStore.guards`），不会和交出去的那一版同号。

## Agent 与 Cue 的通知

到不到你只有 `CueStore.reaches` 一处，他此刻在哪台设备前只按最近一次来到哪台（`Viewer`）；进了等你的事手机总会被叫醒，到不到你只定出不出通知（`CuePush`、`PiPush`）。手机锁屏通知怎么由服务端生成在 `AlertSubscriptions`，两端怎么发在 `AlertCenter`。代码里没写的取舍：

- Mac 不注册远程通知、签名里没有推送权限（aps-environment），通知都是本机发的本地通知；同步到达本来也不靠推送（见「拉取节奏与门铃」）。
- `notify` 是一次性事件标志，通知反映服务端收到记录那一刻的状态：标志在上传前被状态已前进的写入取代就不送出。要保证每个事件都送达得另建追加式的通知事件记录，那是另一种设计。
- 实时活动（`CueLiveActivity`）没有服务端，只由 App 改：推送把 App 叫到后台拉一次，拉完在交还系统之前当场改岛（回调一返回系统就可能挂起）。静默推送是后台优先级，会被合并、节流，被划掉的 App 叫不醒，只走静默推送的变化可能晚到；所以每份的过时时刻是它下一次按时刻变的那一刻（`CueNow.nextShownChange`：过了 `staleAfter` 只信慢的事实、刚做完的到点收掉），系统到点按那时的样子重画，走秒交给系统的计时文字。iCloud 的推送到不了实时活动的推送令牌，通知服务扩展只收可见推送、拿不到资料库，替代不了。没选中继服务（Mac 把计数发给持 APNs 密钥的中继再发 liveactivity 推送：实时、能远程开启，但要运维一个服务、计数要经过我们的服务器）；也不把 APNs 密钥打进 App（谁拿到都能给所有用户推）。
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

### 推送叫醒被系统结束的 App

推送先于同步启动到达：App 被系统结束（内存回收，不是被划掉）后由推送冷启动到后台，拉取要等同步开始了再拉（`CloudSync.syncNow`），拉完、改完小组件与实时活动才交还系统（`IOSAppDelegate` 的远程通知回调）。在 App 切换器里划掉的，系统不再因推送拉起它（Apple 远程通知回调文档），直到用户再打开或重启手机：可见通知照常出（通知服务扩展照常改写），小组件与实时活动不变。没有自动测试：推送不经 Workspace，模拟器登不了 iCloud，CloudKit 也不把推送发给做出改动的那台设备，只能真机加另一台设备验。

1. 两端在同一个环境：生产订阅部署之后，手机装 TestFlight 版、Mac 用正式版；之前用 `xc.sh device` 装的开发构建，Mac 那头起连开发环境的实例（见 [perf.md](perf.md)「同步测量」）。手机打开一次、确认设置里通知那一行正常，主屏放 Cue 小组件。
2. 打开 CuePad 后回主屏、锁屏放一会儿（不要划掉；要验冷启动，等系统回收它，或打开几个大 App 挤掉它）。
3. 在 Mac 上让 Cue 对你说一句不带选项的话（只走静默推送），再说一句带选项的（可见通知，同时叫醒 App）。
4. 不解锁、不打开 App，看小组件与锁屏实时活动：应在几十秒内换成刚说的话。再打开 App：Cue 页里两句已在，不是打开后才转圈拉到。
5. 反例：小组件停在旧内容、打开 App 才出现，就是推送拉起的那一拉空手返回或推送被节流。看手机日志（Mac 上 Console 选这台手机，subsystem 是 App 身份前缀）类别 `sync` 有没有"同步进入等待"（归类与原话）或认账号失败。静默推送每小时只给两三条，连着试几次后它不来是系统节流，换可见通知那句验。
