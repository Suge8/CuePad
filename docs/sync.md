# 同步参考

引擎、协调器、拉取器、上传去重、订阅的实现与理由写在各自文件的头注释里（`CueSync/`、`AppServices+Sync.swift`、`PiStateRecorder.swift`）。这里只补代码看不出的：放慢拉取的条件、发送的约定、通知的取舍、排查与真机验证。

## 拉取节奏

节奏与理由见 `AppServices.pollingCadence` 的注释。Mac 闲着时也每 2 秒拉一次，放慢它的条件：
- 真机上正常用一两天，`ZoneChangePuller.lateCatches` 的日志（子系统 `com.sugeh.cuepad`，类别 `sync`；记的是主动拉取比推送先拿到的记录）很少：每天个位数，且"最久已在服务器上"多在 4–8 秒。
- 满足时才把闲着的一档放慢（`SyncPoller.Cadence` 已支持多档，例如先 2 秒拉两分钟、之后 10 秒一次，一小时 1801 次降到 409 次）；经常出现或动辄几十秒就保持 2 秒。
- 放慢后用设置·同步的"测试到 Mac 的连接"比较闲后第一条请求多等了几秒；这个测试也量端到端往返（上传、Mac 执行完、回到手机三段的中位数）。

## 发送

- 发给 Pi 只有投送请求一种记录。Mac 上发给 Pi 会话（回复框、灵感与任务的发送、菜单栏稿纸）也是写一条指定本机 `hostID` 的投送请求，由本机执行器与手机发来的请求同一流程执行，发起的界面等结果再提示。发给别的 Mac 上在线的会话（Mac 与手机的"交给 Agent"目标是同一批：所有 Mac 上在线的会话，`HandOffTargets`）同样写请求，`hostID` 是会话所在的那台 Mac，写出后立即上传、不等结果，进度和"没能送达"看会话行。
- 直接发送而会话正忙时不写请求，先问"马上说"还是"等它做完再说"。
- 失败原因一律读 `DeliveryRequest.failure`，界面不另写兜底句。
- 方式（`DeliveryMode`）与各自的约定见 `DeliveryRequest.swift` 与 `MacExecutor.swift` 的注释；命令与设置类请求（斜杠命令、会话设置、作答、结束、停止、绑定文件夹）不是说的话，不写发送记录。

## Agent 锁屏通知

- Pi 会话状态记录带明文可查询的 `notify` 标志，是一次性事件标志，只存在于未上传的版本上（理由与规则见 `PiStateRecorder` 与 `PiAlerts.swift`）。
- 取舍：通知反映服务端收到记录那一刻的状态，标志在上传前被状态已前进的写入取代就不送出；状态记录不是事件日志，要保证每个事件都送达需要单独的追加式通知事件记录，那是另一种设计。
- "要不要提示"只有一条规则 `PiAlert.entering`，Mac 置位标志与 iPhone 前台横幅都用它。
- 改订阅的定义（谓词、选项、通知文案 key）等于改 schema，见 [release.md](release.md)。

## 排查与真机验证

App 的日志在 subsystem `com.sugeh.cuepad`（类别 `services`、`launch`、`shutdown`、`pi-history`、`sync`）；CloudKit 与 CKSyncEngine 的日志在 `com.apple.cloudkit`：

```bash
log show --last 30m --info --debug --predicate 'subsystem == "com.sugeh.cuepad" OR (process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit")'
log stream --info --predicate 'process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit"'
```

引擎日志里的错误详情是 `<private>`，看不到原因。要复现：拿用户库的副本、清掉引擎状态，在带生产签名的最小程序里用真实同步代码跑一遍、读问题列表——它会真的上传副本里的待推送记录，只在确认副本内容就是用户本机那份时做。

同步是否真在跑，以库为准（只读复制出来看，不碰用户的库）：`syncState` 有一行 `engine`，`syncRecords` 的行数随推送增长到与同步表记录数相当。真机验证：装发布版 → 打开设置的同步分区，先显示"正在连接 iCloud…"再变"已同步" → 几分钟内复制库检查上面两张表 → 另一台设备上能看到同一批项目、灵感与任务。

验证生产环境的订阅能否创建：用 Developer ID 描述文件签名、带 production 容器权限的最小 Mac 程序保存订阅，打印完整的 CKError（看 `description`，`localizedDescription` 会丢掉服务端的说明）；开发环境的 Mac 描述文件按 Provisioning UDID 登记设备，不是 Hardware UUID。
