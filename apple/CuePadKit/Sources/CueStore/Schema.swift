/// 表分两类。
///
/// 同步表（`Table.synced`，由 CueSync 映射为 CKRecord，record type = 表名，recordName = id）。约束：
/// - 主键是 TEXT UUID（小写），由 Swift 侧生成；
/// - 每条记录有 `modifiedAt`（毫秒），供字段级合并与冲突判断；
/// - 软删除只有 `deletedAt`；
/// - 没有 FOREIGN KEY、UNIQUE：同步乱序送达记录，引用可能先于目标到达，
///   引用完整性由写入逻辑维护（同一事务内清理），同哈希附件的并发重复可容忍；
/// - 列只用 TEXT / INTEGER，能直接映射 CKRecord 字段。
///
/// 同步表里的本机列（不进 CKRecord，记录映射的列表里没有它们）：deliveryRequests.resultReceivedAt、serverAt（服务器收下它的时刻）、cueToldAt（Cue 已知道没送到）；
/// piSessionStates、cards、deliveryRequests、cueMessages 的 writeSeq（本机写入序号，见 `writeSeq`）；attachments.registeredHere（这台设备登记的，见 `registerAttachment`）；
/// piMessages.arrival（读进这台的次序，这张表的主键让给了它、id 改由 UNIQUE 守，见 `messageArrivalUpgrade`）。
///
/// 本机表（不同步）：`Table.synced` 之外的表，另有 piProcesses、syncRecords、syncState，以及 searchIndex（FTS5，由触发器随同步表维护，可随时重建）；
/// cueSummaries 是 Cue 记忆的摘要缓存，可随时丢弃重建。
///
/// 同步表只加表或可空列，不改已有列：其他版本的设备仍按旧字段读写同一批记录。下线的字段与表删掉本地列、不再读写，
/// CloudKit 里照原样声明为已下线（`CloudKitSchema.retiredFields` / `retiredTypes`，生产环境删不掉）。
enum Schema {
  /// 一步结构升级：多数是 SQL；要用 Swift 算的（如按正文规则取标题）给一个闭包。都在同一个事务里执行。
  /// 要动附件文件的（78）拿到这个库的 `AttachmentFiles`：事务里只许新增（链接），不可回滚的删除交回 `AfterCommit`，等整个升级提交之后再做——
  /// 事务回滚时旧文件原样还在，下次重跑读到的与第一次相同。
  struct Upgrade: ExpressibleByStringInterpolation, Sendable {
    typealias AfterCommit = @Sendable () -> Void
    let run: @Sendable (SQLite, AttachmentFiles) throws -> AfterCommit?

    init(stringLiteral sql: String) { run = { db, _ in try db.exec(sql); return nil } }
    init(stringInterpolation: DefaultStringInterpolation) { self.init(stringLiteral: String(stringInterpolation: stringInterpolation)) }
    init(_ run: @escaping @Sendable (SQLite) throws -> Void) { self.run = { db, _ in try run(db); return nil } }
    init(files run: @escaping @Sendable (SQLite, AttachmentFiles) throws -> AfterCommit?) { self.run = run }
  }

  /// 能打开的最老结构版本（`upgrades` 的起点）：更早的库不升级、不打开（`schemaTooOld`），也没有就地重建的入口。
  /// 只有作者自己的设备在用：起点可以挪到这些设备的库都已升过的那一版，却不能高于任何一个 `mac/`、`ios/` 发布标签那时的结构。
  /// 72 是 ios/2610262136；标签从它起才有，更早也发过 Sparkle 与 TestFlight 构建，它们的库自 10-23 起点到 66 就已打不开。
  /// 挪起点时把那一版及以前的步骤折进 `create`（它建的就是最新结构），给更早设备留的兼容一并删掉。
  static let baseVersion = 72

  /// 最低对端版本（CueSync 的 `PeerFloor`）：更早的设备停下收发、提示更新。只在旧版照新写法读写会做错事时抬到那一版——把新写法误读成别的意思、
  /// 写回时盖掉新字段、读不出就卡住同步；新加的表、字段与句式旧版只是不认（照旧字段显示、跳过读不出的），不抬：一抬，旧设备在更新前什么都发不出去。
  /// 抬的那一版先发 iOS、TestFlight 处理完再发 Mac：Mac 经 Sparkle 几分钟就装上，反过来发，苹果处理 iOS 的那段时间里手机停下收发。与 `baseVersion` 各定各的。
  /// 78：附件换了地址（`cuepad://file/<键>`）：旧版 Mac 认不出，把链接原文发给 Agent，旧版手机显示不出图与文件。
  /// 82：旧客户端忽略额度能力与授权分区，会把失败或过期窗口显示成可用余额。
  /// 87：旧端会忽略配置请求里的 fast，错误地把部分执行报告成成功。
  /// 89：一台设备可同时开多个会话；旧端只读 sessionID，会把开着的另一页当作无人查看、错误推送。
  /// 不抬的例：派发期限改从服务器收下起算（90）。旧版 Mac 缺附件时不守期限是它原有的缺陷，不是误读新写法；新手机照常登记、上传附件，旧 Mac 取得到。
  /// 93：旧端会把晚到投送重新关联，也会误结束纯关联的托管会话；自动结束请求须由新端复核创建来源。
  static let peerFloor = 93

  /// `upgrades[i]` 把结构版本 `baseVersion + i` 升到 `baseVersion + i + 1`；改结构时在末尾追加一步，同时更新 `create`
  /// （新库直接建成最新结构、不跑升级步骤：只改数据的一步在空库上无事可做）。
  /// 一步里任何会因数据冲突失败的语句（加唯一索引、NOT NULL、按假定的数据形状改写）都会让启动失败、库打不开：
  /// 要按别的设备已经同步来的、任意形状的数据写。
  static let upgrades: [Upgrade] = [
    // 73：他最近一次来到这台设备的时刻（`Viewer.arrivedAt`）：他此刻在哪台设备前只按它判断
    "ALTER TABLE sessionViewers ADD COLUMN arrivedAt INTEGER;",
    // 74：投送请求记下服务器收下它的时刻（本机列，拉到时由服务器的记录给），派发期限从它算（`DeliveryRequest.dispatchDeadline`）；已有的照写下的时刻算
    "ALTER TABLE deliveryRequests ADD COLUMN serverAt INTEGER;",
    // 75：定时（`CueMemoryLine`）：重复规则与挂在哪件任务上
    "ALTER TABLE cueLines ADD COLUMN repeats TEXT; ALTER TABLE cueLines ADD COLUMN taskID TEXT;",
    // 76：各台 Mac 的技能与规则（`AgentLibrary`）
    "\(agentLibrariesTable) \(modifiedIndex(.agentLibraries))",
    // 77：技能与规则每份文件的正文各一条（`LibraryFileText`），快照里只留哈希（76 没发出去过，没有旧写法的快照要认）
    "\(agentLibraryFilesTable) \(modifiedIndex(.agentLibraryFiles))",
    // 78：附件按键存取，旧引用、记录与文件改到新写法（`keyedAttachments`）
    Upgrade(files: keyedAttachments),
    // 79：项目按最近的进展排（`CueStore.projectOrder`），换成按进展时刻的索引；只是本机索引，不碰同步的字段
    "DROP INDEX IF EXISTS cards_projectID_modifiedAt; \(progressIndexes)",
    // 80：Cue 记下的记忆去掉开头的记下时间与"他说"（`plainCueLines`）；只改数据，改过的同步出去
    Upgrade(plainCueLines),
    // 81：会话出错的种类（`FailureKind`），Mac 记下状态时定、各端只读；从更早的版本重跑到这一步时（新建的库已有这一列）不再加
    Upgrade { (db: SQLite) in
      guard try db.first("SELECT 1 FROM pragma_table_info('piSessionStates') WHERE name = 'failure'", [], { _ in true }) == nil else { return }
      try db.exec("ALTER TABLE piSessionStates ADD COLUMN failure TEXT;")
    },
    // 82：额度按宿主授权分区，能力、失败与最后观测的时刻一起同步；旧记录没有授权事实，只能作为未知数据
    "ALTER TABLE accountQuotas ADD COLUMN account TEXT; ALTER TABLE accountQuotas ADD COLUMN status TEXT; ALTER TABLE accountQuotas ADD COLUMN observedAt INTEGER;",
    // 83：运行报告与所属 Mac 的系统启动关联；旧端忽略关联与投送 unknown，会错误授权控制或重投。旧报告不回填证明。
    // 旧 failed 混着没交出与领取后结果不明：按领取事实分开（不猜原因文案），改过的同步出去。
    """
    ALTER TABLE piSessionStates ADD COLUMN bootID TEXT; ALTER TABLE macPresence ADD COLUMN bootID TEXT;
    ALTER TABLE cueState ADD COLUMN hostID TEXT; ALTER TABLE cueState ADD COLUMN bootID TEXT;
    DROP TRIGGER piSessionStates_writeSeq_update;
    \(updateStamp("piSessionStates", when: sessionChanges))
    UPDATE deliveryRequests SET status = CASE WHEN handledBy IS NULL THEN '\(DeliveryStatus.failed.rawValue)' ELSE '\(DeliveryStatus.unconfirmed.rawValue)' END,
      modifiedAt = modifiedAt + 1
    WHERE status = 'failed';
    """,
    // 84：执行与历史确认分别持有硬截止；旧端会把 confirming 写回未确认，必须一起更新。旧记录不补造期限。
    "ALTER TABLE deliveryRequests ADD COLUMN deadlineAt INTEGER;",
    // 85：82 的两种布局分别含活动地址与额度授权字段；补齐缺少的部分，不替旧报告或投送补造证明。
    Upgrade { db in
      try db.exec("\(activityDestinationsTable) CREATE INDEX IF NOT EXISTS activityDestinations_modified ON activityDestinations(id, modifiedAt);")
      let columns = Set(try db.query("PRAGMA table_info(accountQuotas)") { $0.text(1) })
      for (name, type) in [("account", "TEXT"), ("status", "TEXT"), ("observedAt", "INTEGER")] where !columns.contains(name) {
        try db.exec("ALTER TABLE accountQuotas ADD COLUMN \(name) \(type);")
      }
    },
    // 86：preparing 只等现有会话就绪，未派发且可撤回；85 客户端不能正确合并这个阶段。
    Upgrade { _ in },
    // 87：fast 随会话状态与 Cue 配置同步；旧端会忽略配置请求中的 fast。
    Upgrade { db in
      for table in ["piSessionStates", "cueProfile"] {
        let exists = try db.first("SELECT 1 FROM pragma_table_info(?) WHERE name = 'fast'", [table]) { _ in true }
        if exists == nil { try db.exec("ALTER TABLE \(table) ADD COLUMN fast INTEGER") }
      }
    },
    // 88：余额与套餐明细、结果的排序时刻；旧端仍可读固定窗口，缺明细不构造余额。`owners`（证明过网关来源的提供方与时刻）只在本机、不同步。
    // 同 85，只补缺的列（新建的库已有）。
    Upgrade { db in
      let columns = Set(try db.query("PRAGMA table_info(accountQuotas)") { $0.text(1) })
      for (name, type) in [("details", "TEXT"), ("requestedAt", "INTEGER"), ("owners", "TEXT")] where !columns.contains(name) {
        try db.exec("ALTER TABLE accountQuotas ADD COLUMN \(name) \(type);")
      }
    },
    // 89：开着的会话改存集合；旧单值只在升级时转入，本地旧列删掉，CloudKit 字段登记下线。
    """
    ALTER TABLE sessionViewers ADD COLUMN sessionIDs TEXT;
    UPDATE sessionViewers SET sessionIDs = json_array(sessionID) WHERE sessionID IS NOT NULL;
    ALTER TABLE sessionViewers DROP COLUMN sessionID;
    """,
    // 90：派发期限从服务器收下起算（`DeliveryRequest.dispatchDeadline`）；升级前已传上去、还在等派发的，发送方没记下收下时刻，
    // 不补就永远不到期：按写下的时刻补（只改本机列，不改 modifiedAt、不同步）
    "\(deliveryServerAnchor)",
    // 91：摘要改为绑定生成输入的完整指纹；旧派生缓存丢弃重建。
    "DELETE FROM cueSummaries;",
    cueMessageUpgrade,
    taskSessionUpgrade,
    // 94：会话来源（piSessions、piSessionStates 的 agent）早于多家接入写下的为空，是 Pi：就地补上，之后按列直接读；不改 modifiedAt（不同步出去），
    // 云端留着的旧记录在落库时补（`applyVersion`）
    """
    UPDATE piSessions SET agent = '\(AgentKind.pi.rawValue)' WHERE agent IS NULL;
    UPDATE piSessionStates SET agent = '\(AgentKind.pi.rawValue)' WHERE agent IS NULL;
    DROP INDEX piSessions_agent; \(agentIndex)
    """,
    // 95：附件记录是不是这台设备登记的（本机列，不同步、不改 modifiedAt），启动清理只收这种（`removeStrayFiles`）。
    // 升级前已有的一律留空、当作别处来的：其中编辑删图后再永久删卡漏下的记录与文件照旧留着，宁可不释放，也不误删别的设备上的图
    "ALTER TABLE attachments ADD COLUMN registeredHere INTEGER;",
    // 96：Cue 通话的音色（`CueVoice`）；空着的按默认
    "ALTER TABLE cueProfile ADD COLUMN voice TEXT;",
    messageArrivalUpgrade,
  ]

  static let activityDestinationsTable = """
    CREATE TABLE IF NOT EXISTS activityDestinations (
      id TEXT PRIMARY KEY NOT NULL, device TEXT NOT NULL, activityID TEXT NOT NULL, token TEXT NOT NULL,
      environment TEXT NOT NULL, startedAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    """

  static let agentLibraryFilesTable = """
    CREATE TABLE agentLibraryFiles (
      id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, path TEXT NOT NULL, hash TEXT NOT NULL, text TEXT NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX agentLibraryFiles_host ON agentLibraryFiles(hostID);
    """

  static let agentLibrariesTable = """
    CREATE TABLE agentLibraries (
      id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, home TEXT NOT NULL, skills TEXT, instructions TEXT, tidies TEXT, selfManaged TEXT,
      agents TEXT, modifiedAt INTEGER NOT NULL
    ) STRICT;
    """

  /// 升级腾出了大量空页（删列、清缓存）时整理一遍，把它们还给磁盘：库不开自动整理，空页只等以后的写入复用，文件不会变小。
  /// 别的进程（命令行、扩展）正开着库时整理不了（忙），空页留着照样复用，不挡打开。
  static func reclaim(_ db: SQLite) throws {
    let free = try db.first("PRAGMA freelist_count") { $0.int(0) } ?? 0
    let total = try db.first("PRAGMA page_count") { $0.int(0) } ?? 0
    guard free * 4 > total else { return }
    try? db.exec("VACUUM")
  }

  /// 同步元数据：每条记录服务器端的系统字段（压缩存，见 `SystemFields`）与服务器收下的修改时间（从没收下过为 NULL），以及本机交出去的那一版的修改时间
  /// （sentModifiedAt，见 `CueStore.noteSent`）。服务器收下过而行已不在数据表里的，就是要向服务器删除的（不需要墓碑表）。
  static let syncRecordsTable = """
    CREATE TABLE syncRecords (
      recordName TEXT PRIMARY KEY NOT NULL, recordType TEXT NOT NULL, systemFields BLOB,
      pushedModifiedAt INTEGER, sentModifiedAt INTEGER
    ) STRICT;
    """
  static let syncRecordsIndexes = """
    CREATE INDEX syncRecords_recordType ON syncRecords(recordType, pushedModifiedAt, recordName);
    CREATE INDEX syncRecords_pushed ON syncRecords(recordName, pushedModifiedAt);
    """

  /// `PRAGMA user_version`：空库为 0，建好后为 `version`；旧于 `baseVersion` 的拒绝打开；其余旧的按 `upgrades` 就地升级；
  /// 比它新的是更新版本建的库，不打开。
  static let version = baseVersion + upgrades.count
}
