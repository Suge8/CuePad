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
/// piSessionStates、cards、deliveryRequests 的 writeSeq（本机写入序号，见 `writeSeq`）。
///
/// 本机表（不同步）：`Table.synced` 之外的表，另有 piProcesses、syncRecords、syncState，以及 searchIndex（FTS5，由触发器随同步表维护，可随时重建）；
/// cueSummaries 是 Cue 记忆的摘要缓存，可随时丢弃重建。
///
/// 同步表只加表或可空列，不改已有列：其他版本的设备仍按旧字段读写同一批记录。下线的字段与表删掉本地列、不再读写，
/// CloudKit 里照原样声明为已下线（`CloudKitSchema.retiredFields` / `retiredTypes`，生产环境删不掉）。
enum Schema {
  /// 一步结构升级：多数是 SQL；要用 Swift 算的（如按正文规则取标题）给一个闭包。都在同一个事务里执行。
  struct Upgrade: ExpressibleByStringInterpolation, Sendable {
    let run: @Sendable (SQLite) throws -> Void

    init(stringLiteral sql: String) { run = { try $0.exec(sql) } }
    init(stringInterpolation: DefaultStringInterpolation) { self.init(stringLiteral: String(stringInterpolation: stringInterpolation)) }
    init(_ run: @escaping @Sendable (SQLite) throws -> Void) { self.run = run }
  }

  /// 能打开的最老结构版本（`upgrades` 的起点）：更早的库不升级、不打开（`schemaTooOld`）。发出的版本把用户的库都升过了某一版，就把那一版及以前的步骤折进 `create`、起点挪到那一版：
  /// `create` 建的就是最新结构，升级步骤只留还有库没跑过的，给更早设备留的兼容一并删掉。
  static let baseVersion = 66

  /// 最低对端版本（CueSync 的 `PeerFloor`）：更早的设备停下收发、提示更新。只在旧版照新写法读写会做错事时抬到那一版——把新写法误读成别的意思、
  /// 写回时盖掉新字段、读不出就卡住同步；新加的表、字段与句式旧版只是不认（照旧字段显示、跳过读不出的），不抬：一抬，旧设备在更新前什么都发不出去。
  /// 抬的那一版先发 iOS、TestFlight 处理完再发 Mac（docs/release.md「发版顺序」）。与 `baseVersion` 分开：本机的库要等用户的库都升过才折进 `create`。
  /// 75：旧版值班会把到点的重复定时（`CueMemoryLine.repeats`）当一次性的清掉下一次、不再重复。
  static let peerFloor = 75

  /// `upgrades[i]` 把结构版本 `baseVersion + i` 升到 `baseVersion + i + 1`；改结构时在末尾追加一步，同时更新 `create`
  /// （新库直接建成最新结构、不跑升级步骤：只改数据的一步在空库上无事可做）。
  /// 一步里任何会因数据冲突失败的语句（加唯一索引、NOT NULL、按假定的数据形状改写）都会让启动失败、库打不开：
  /// 要按别的设备已经同步来的、任意形状的数据写。
  static let upgrades: [Upgrade] = [
    // 67：
    // - 同步元数据的系统字段压缩存（`SystemFields`），真实库从 65MB 降到约 10MB。原地改写的行仍各占一页，所以整表重建：
    //   一条 INSERT … SELECT 按行压缩，建好再补索引；腾出的页由升级后的整理还给磁盘（`reclaim`）
    // - 启动与每次会话、Cue 对话变化都要读的几处走索引（各自的理由见它们的定义）
    // - 会话消息不再盖写入序号（没有读者）：会话里每多一条消息，值班的 Cue 就不再多对一次账
    Upgrade { db in
      try db.define("packSystemFields", SystemFields.pack)
      try db.exec(
        """
        ALTER TABLE syncRecords RENAME TO syncRecordsOld; DROP INDEX syncRecords_recordType; DROP INDEX syncRecords_pushed;
        \(syncRecordsTable)
        INSERT INTO syncRecords SELECT recordName, recordType, packSystemFields(systemFields), pushedModifiedAt, sentModifiedAt FROM syncRecordsOld;
        DROP TABLE syncRecordsOld;
        \(syncRecordsIndexes)
        DROP INDEX piSessionStates_state; \(stateIndex) \(launchTokenIndex) \(hostedIndex) \(toDeliverIndex)
        DROP TRIGGER piMessages_writeSeq_insert; ALTER TABLE piMessages DROP COLUMN writeSeq;
        """)
    },
    // 68：Cue 此刻正在跑的那一步碰到的那一处（`CueState.step`）
    "ALTER TABLE cueState ADD COLUMN step TEXT;",
    // 69：不用先问的例外并进记忆：允许清单（cueProfile.allows，"类别"或"类别/项目 id"）每项转成一条他说的、一直记着的记忆，字是这一步写下时提问卡的第二项
    // （照抄在这里，之后改 `CueAsk` 的字不改这一步写出的；项目名照样截短，`CueMemoryLine.fitting`；项目已不在的、当时就不能放行的那项丢掉），清单那一列删掉。
    // 每台设备各自升级：行的 id 与时刻由清单项与设置的修改时间推出，写出的是同一行
    Upgrade { db in
      let names = [
        "push": "推送代码", "merge": "合并进共享分支", "release": "发布或部署", "delete": "删除文件、分支或数据", "outside": "动项目外的东西",
        "budget": "超出预算",
      ]
      let profile = try db.first("SELECT allows, modifiedAt FROM cueProfile") { (allows: $0.textOrNil(0), at: $0.int(1)) }
      let projects = Dictionary(try db.query("SELECT id, name FROM projects") { ($0.text(0), $0.text(1)) }, uniquingKeysWith: { first, _ in first })
      for item in JSONColumn.decodeList(String.self, from: profile?.allows) {
        let parts = item.split(separator: "/", maxSplits: 1).map(String.init)
        let project = parts.count > 1 ? projects[parts[1]] : nil
        guard let profile, let name = names[parts[0]], parts.count == 1 || project != nil else { continue }
        let text = project.map { CueMemoryLine.fitting($0) { "以后「\($0)」里\(name)不用问" } } ?? "以后\(name)都不用问"
        try db.run(
          "INSERT OR IGNORE INTO cueLines (id, text, pinned, source, createdAt, modifiedAt) VALUES (?1, ?2, 1, 'you', ?3, ?3)",
          [DeterministicID.uuid("cue-allow/\(item)"), text, profile.at])
      }
      try db.exec("ALTER TABLE cueProfile DROP COLUMN allows")
    },
    // 70：留空。它曾把醒来记录的名字补进明文的 wake，没发布就撤回了（名字是用户内容，改进加密的 places，见 71）；号留着，走过它的开发库照常往下升，
    // 那里 wake 里多出的 name 由 71 抹掉
    Upgrade { _ in },
    // 71：对话记下写下那一刻提到的那几处的样子（`CuePlace`：关联任务的名字、状态与子任务进度，叫醒 Cue 的会话、任务的名字），Cue 页只按记录画。
    // 之前写下的补上升级时的样子（记录已不在的不补），wake 按现在的 `CueWake` 重写一遍（抹掉 70 补进去的明文名字）；
    // 每台设备各自升级、不改 modifiedAt（不同步出去）：同一份数据补出同一份
    Upgrade { db in
      try db.exec("ALTER TABLE cueMessages ADD COLUMN places TEXT")
      let rows = try db.query("SELECT id, taskID, wake FROM cueMessages WHERE taskID IS NOT NULL OR wake LIKE '%sessionActivity%'") {
        (id: $0.text(0), task: $0.uuidOrNil(1), wake: $0.textOrNil(2).flatMap(CueWake.init(stored:)))
      }
      for row in rows {
        let places = try CuePlace.capture(task: row.task, wake: row.wake, in: db)
        try db.run(
          "UPDATE cueMessages SET places = ?, wake = coalesce(?, wake) WHERE id = ?",
          [places.isEmpty ? nil : JSONColumn.encode(places), row.wake?.stored, row.id])
      }
    },
    // 72：Mac 写下、同步给各端的界面字改存句式与参数（`ShownText`），各端按自己的语言显示：
    // - 投送没送到的原因换成新列 failure（resultDetail 下线）；已有的原因是写下那台的原文，照原文存
    // - CuePad 代 Cue 写下的话存进新列 shownText，正文列留空；已有的做完的结果（`CueReport`）拆回任务名与证据
    // - 你在 CuePad 里答确认框的是否存进新列 piMessages.shownText；已有的作答分不出是不是确认框，照原文
    // - 提问的选项各端照类别与范围写（`CueMessage.shownChoice`）：已有的提问补上范围那个项目此刻的名字（`CuePlace`）
    // 每台设备各自升级、不改 modifiedAt（不同步出去）：同一份数据改出同一份
    Upgrade(shownTexts),
    // 73：他最近一次来到这台设备的时刻（`Viewer.arrivedAt`）：他此刻在哪台设备前只按它判断
    "ALTER TABLE sessionViewers ADD COLUMN arrivedAt INTEGER;",
    // 74：投送请求记下服务器收下它的时刻（本机列，拉到时由服务器的记录给），执行的 Mac 按它算过期（`DeliveryExecutor.maxAge`）；已有的照写下的时刻算
    "ALTER TABLE deliveryRequests ADD COLUMN serverAt INTEGER;",
    // 75：定时（`CueMemoryLine`）：重复规则与挂在哪件任务上
    "ALTER TABLE cueLines ADD COLUMN repeats TEXT; ALTER TABLE cueLines ADD COLUMN taskID TEXT;",
    // 76：各台 Mac 的技能与规则（`AgentLibrary`）
    "\(agentLibrariesTable) \(modifiedIndex(.agentLibraries))",
  ]

  /// 技能与规则的快照：每台 Mac 自己写一条、各端读（`AgentLibrary`）。
  static let agentLibrariesTable = """
    CREATE TABLE agentLibraries (
      id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, home TEXT NOT NULL, skills TEXT, instructions TEXT, tidies TEXT, selfManaged TEXT,
      agents TEXT, modifiedAt INTEGER NOT NULL
    ) STRICT;
    """

  /// 72 的那一步（见 `upgrades` 里的说明）。
  private static func shownTexts(_ db: SQLite) throws {
    try db.exec("ALTER TABLE deliveryRequests RENAME COLUMN resultDetail TO failure; ALTER TABLE cueMessages ADD COLUMN shownText TEXT; ALTER TABLE piMessages ADD COLUMN shownText TEXT;")
    let failures = try db.query("SELECT id, failure FROM deliveryRequests WHERE failure IS NOT NULL") { ($0.text(0), $0.text(1)) }
    for (id, reason) in failures {
      try db.run("UPDATE deliveryRequests SET failure = ? WHERE id = ?", [ShownText.verbatim(reason).stored, id])
    }
    let reports = try db.query("SELECT id, text FROM cueMessages WHERE author = 'cue' AND taskID IS NOT NULL AND text LIKE '「%'") { ($0.text(0), $0.text(1)) }
    for (id, text) in reports {
      guard let end = text.range(of: "」做完了\n\n") else { continue }
      let task = String(text[text.index(after: text.startIndex)..<end.lowerBound]), evidence = String(text[end.upperBound...])
      try db.run("UPDATE cueMessages SET text = '', shownText = ? WHERE id = ?", [ShownText("「\(task)」做完了\n\n\(evidence)").stored, id])
    }
    let asked = try db.query("SELECT id, ask, places FROM cueMessages WHERE ask LIKE '%/%'") { ($0.text(0), $0.text(1), $0.textOrNil(2)) }
    for (id, ask, stored) in asked {
      guard let project = CueAsked(stored: ask)?.project else { continue }
      var places = JSONColumn.decode([String: CuePlace].self, from: stored) ?? [:]
      places.merge(try CuePlace.capture(task: nil, wake: nil, project: project, in: db)) { old, _ in old }
      try db.run("UPDATE cueMessages SET places = ? WHERE id = ?", [places.isEmpty ? nil : JSONColumn.encode(places), id])
    }
  }

  /// 升级腾出了大量空页（如 67 把系统字段压小）时整理一遍，把它们还给磁盘：库不开自动整理，空页只等以后的写入复用，文件不会变小。
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
