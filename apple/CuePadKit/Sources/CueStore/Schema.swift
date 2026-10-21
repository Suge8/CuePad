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
/// 同步表里的本机列（不进 CKRecord，记录映射的列表里没有它们）：deliveryRequests.resultReceivedAt、cueToldAt（Cue 已知道没送到）；
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

  /// 能打开的最老结构版本（`upgrades` 的起点），也是这台要求的最低对端版本（CueSync 的 `PeerFloor`）：更早的库不升级、不打开
  /// （`schemaTooOld`），更早的设备不再同步。发出的版本把用户的库都升过了某一版，就把那一版及以前的步骤折进 `create`、起点挪到那一版：
  /// `create` 建的就是最新结构，升级步骤只留还有库没跑过的，给更早设备留的兼容一并删掉。
  static let baseVersion = 66

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
  ]

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
