# 同步参考

同步通路、拉取、发送与通知的规则和理由写在各自类型的头注释里：通路与为什么不用 CKSyncEngine 在 `CloudSync`，拉、推在 `ZonePuller`、`RecordSender`，等待理由与立即同步在 `AppServices+Sync.swift`，说的话到哪了在 `Speech`。这里只补代码里没有的：实测结论、跨设备的取舍、排查与真机验证。

## 拉取节奏

**Mac 的 2 秒拉取是别的设备写来的请求与对 Cue 说的话到达 Mac 的唯一通路，别放慢、别删。** 节奏在 `SyncPoller.Cadence`，等待理由只在 `AppServices.pollingCadence` 加。

- 实测（2026-10-12，手机发 18 条请求）：服务器到 Mac 0.44–2.67 秒、中位约 1.1 秒，全靠拉取到达。改节奏前先有新的实测，不凭"每天四万多次请求太多"去放慢。
- Cue 值班是等待理由：2026-10-14 手机对 Cue 说的一句 21 秒才交给它，当时 Mac 没有等待理由、一次都没拉。没开 1 秒一档：Cue 回一句本身要十几到几十秒。
- 不是等待理由的改动（灵感、任务等）靠切到前台、唤醒时的立即同步，手机另有推送。

## 发送

- 所有发给 Agent 与 Cue 的话都经 `Workspace.speak` 写一条投送请求或 Cue 消息，界面不等上传与结果（`lint.sh` 查）。方式与各自的约定在 `DeliveryMode`，执行与重试在 `DeliveryExecutor`、`MacExecutor`。
- 终端里的 Claude Code 在跑时说不了，规则只在 `AgentCapabilities.speakBlocked`。

## 说的话的链路

状态与时限只在 `Speech`。一句话从按发送到本机看到回执走的通路，排查慢在哪一段时对照：

1. 按发送 → 本机库：先清空输入框，再写一条记录（毫秒级）。
2. 本机 → 服务器：马上传（`CloudSync.send`），多数 1 秒内，偶尔约 10 秒（issue #2，没有定论）。
3. 服务器 → 接收的 Mac：只靠 Mac 的 2 秒拉取，平均约 1 秒、最坏约 2 秒。
4. Mac 交给 Agent 或 Cue：0.2 秒内；领取、写回结果、交给 Cue 后都马上传。
5. 服务器 → 发出方：手机有在等回执的话时每 2 秒拉，另有推送。
6. 进对话：Mac 读到会话文件里带请求标识的那条，在同一个事务里收走请求，气泡由对话里那条接替（`PiChat.outgoing`）。

Cue 说话的工具等结果至多 `Speech.cueWait`；没告诉它的失败作为"[发送失败]"写进它下一轮的变化并叫醒它（`CueTools`、`cueToldAt`）。

## Mac 在线

每台设备自己写、别的设备只读的三张同步表，规则与写的时机在各自头注释：在不在线 `MacPresence`（`MacPresenceKeeper`）、开着哪一页 `Viewer`（`ViewerKeeper`）、有哪些 Agent 与模型 `MacAgents`（`MacAgentsRecorder`）。它们都不是等待理由：需要及时看到的那台 Mac 本来就因在线会话或 Cue 值班每 2 秒拉。

推送的取舍：手机的同步区变化推送对每次写都推一次，续期就是醒着的每台 Mac 每小时约 12 次。Apple 建议后台推送每小时不超过两三次，超了系统会合并、节流；"等你"与 Agent 的提醒是查询订阅的可见推送，不受影响。接受这个代价，没把在线记录挪到手机不订阅的单独同步区（要多一个区、一份令牌和一条拉取）。实测到手机耗电或别的后台推送被节流时，先拉长 `MacPresence.renewal`，再考虑单独的区。

## 最低对端版本

跨版本兼容只有一个门槛，规则在 `PeerFloor`：上调就是挪 `Schema.baseVersion`，同一个改动里删掉给更早设备留的兼容。门槛只拦得住认它的版本（2026-10 起），所有设备都升到这之后的版本前，不能凭它删兼容。

## 自己的回声不是冲突

本机上传的版本会经拉取回到本机，当成并发编辑就每次留一张冲突副本（2026-10-12 一台 Mac 上 4 分钟 17 张，当时有两路上传）。认法在 `CueStore` 的 `applyVersion`。前提：别的设备的并发编辑晚于本机上次同步的版本（时钟大致对准），且不与本机交出去的那一版落在同一毫秒。

## Agent 与 Cue 的通知

到不到你只有 `CueStore.reaches` 一处；手机锁屏通知怎么由服务端生成在 `AlertSubscriptions`，两端怎么发在 `AlertCenter`。代码里没写的取舍：

- Mac 不注册远程通知、签名里没有推送权限（aps-environment），通知都是本机发的本地通知；同步到达本来也不靠推送（见「拉取节奏」）。
- `notify` 是一次性事件标志，通知反映服务端收到记录那一刻的状态：标志在上传前被状态已前进的写入取代就不送出。要保证每个事件都送达得另建追加式的通知事件记录，那是另一种设计。
- 实时活动（`CueLiveActivity`）没有服务端，只由 App 改：推送把 App 叫到后台拉一次，拉完在交还系统之前当场改岛（回调一返回系统就可能挂起）。静默推送是后台优先级，会被合并、节流，被划掉的 App 叫不醒，只走静默推送的变化可能晚到；所以每份带过时时刻（`CueNow.staleAfter`），过了只信慢的事实，走秒交给系统的计时文字。iCloud 的推送到不了实时活动的推送令牌，通知服务扩展只收可见推送、拿不到资料库，替代不了。没选中继服务（Mac 把计数发给持 APNs 密钥的中继再发 liveactivity 推送：实时、能远程开启，但要运维一个服务、计数要经过我们的服务器）；也不把 APNs 密钥打进 App（谁拿到都能给所有用户推）。
- Mac 提示音装进 ~/Library/Sounds（`AlertSounds`），卸载 App 后会留下，也会出现在系统设置的提示音列表里。
- 改订阅的定义（谓词、选项、通知文案 key）等于改 schema，见 [release.md](release.md)。

## 排查与真机验证

投送请求的时间线：手机每次马上传一行"用时"（类别 `services`）；Mac 每条请求到达一行"创建后 X 秒到服务器，再 Y 秒到本机"、领取一行"创建后 X 秒"（类别 `delivery`）。X 大是发送方上传慢，Y 大是拉取慢，到达与领取的间隔大是执行器。整批上传失败与拉取失败在类别 `sync`，带错误码与服务器说明。

App 的日志在 subsystem 即 App 身份前缀（`Signing.xcconfig` 的 `CUEPAD_APP_ID`），CloudKit 的在 `com.apple.cloudkit`：

```bash
id=$(sed -n 's/^CUEPAD_APP_ID *= *//p' apple/App/Config/Signing.xcconfig)
log show --last 30m --info --debug --predicate "subsystem == \"$id\" OR (process == \"CuePad\" AND subsystem BEGINSWITH \"com.apple.cloudkit\")"
log stream --info --predicate 'process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit"'
```

CloudKit 日志里的错误详情是 `<private>`。要复现：拿用户库的副本、清掉 `syncState`，在带生产签名的最小程序里用真实同步代码跑一遍、读问题列表——它会真的上传副本里的待推送记录，只在确认副本内容就是用户本机那份时做。

同步是否真在跑以库为准（只读复制出来看）：`syncState` 有一行 `zoneToken`，`syncRecords` 的行数随推送增长到与同步表记录数相当。真机验证：装发布版 → 设置里的 iCloud 同步先显示"正在连接 iCloud…"再变"已同步" → 几分钟内复制库检查这两张表 → 另一台设备上看到同一批项目、灵感与任务。

验证生产环境的订阅能否创建：用 Developer ID 描述文件签名、带 production 容器权限的最小 Mac 程序保存订阅，打印完整的 CKError（看 `description`，`localizedDescription` 会丢掉服务端的说明）。开发环境的 Mac 描述文件按 Provisioning UDID 登记设备，不是 Hardware UUID。
