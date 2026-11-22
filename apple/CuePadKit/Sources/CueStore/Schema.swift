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
/// 同步表的列与去向（明文、加密、只留本机）见 `Table.syncedFields`、`Table.localColumns`。
///
/// 本机表（不同步）：`Table.synced` 之外的表，另有 piProcesses、syncRecords、syncState，以及 searchIndex（FTS5，由触发器随同步表维护，可随时重建）；
/// cueSummaries 是 Cue 记忆的摘要缓存，可随时丢弃重建。
///
/// 同步表只加表或可空列，不改已有列：其他版本的设备仍按旧字段读写同一批记录。下线的字段与表删掉本地列、不再读写，
/// CloudKit 里照原样声明为已下线（`CloudKitSchema.retiredFields` / `retiredTypes`，生产环境删不掉）。
enum Schema {
  static let baseVersion = 98

  /// 最低对端版本（CueSync 的 `PeerFloor`）：更早的设备停下收发、提示更新。只在旧版照新写法读写会做错事时抬到那一版——把新写法误读成别的意思、
  /// 写回时盖掉新字段、读不出就卡住同步、不认新字段就照旧做而旧做法正是新规矩要拦的、还在写新版已下线的字段；新加的表、字段与句式旧版只是不认
  /// （照旧字段显示、跳过读不出的）、照旧做也没错的，不抬：一抬，旧设备在更新前什么都发不出去。
  /// 抬的那一版先发 iOS、TestFlight 处理完再发 Mac：Mac 经 Sparkle 几分钟就装上，反过来发，苹果处理 iOS 的那段时间里手机停下收发。与 `baseVersion` 各定各的。
  /// 93：旧端会把晚到投送重新关联，也会误结束纯关联的托管会话；自动结束请求须由新端复核创建来源。
  /// 104：旧端的 Cue 不认会话的档位，他选了自己来照样替他答；旧端在拍板卡上点的答案新端收不到。
  static let peerFloor = 104

  static let upgrades = [
    "ALTER TABLE piSessionStates ADD COLUMN turnDelivery TEXT; ALTER TABLE piSessionStates ADD COLUMN turnByCue INTEGER;",
    "ALTER TABLE piSessionStates ADD COLUMN restoredAt INTEGER;",
    "ALTER TABLE cards ADD COLUMN shelvedUntil INTEGER; ALTER TABLE cards ADD COLUMN seenAt INTEGER;",
    """
    ALTER TABLE cards DROP COLUMN shelvedUntil;
    ALTER TABLE cards DROP COLUMN seenAt;
    DROP TABLE cueRead;
    DELETE FROM syncRecords WHERE recordType = 'cueRead';
    CREATE TABLE marks (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, subject TEXT NOT NULL, modifiedAt INTEGER NOT NULL) STRICT;
    CREATE INDEX marks_kind ON marks(kind, subject, modifiedAt);
    \(Schema.modifiedIndex(.marks))
    """,
    liveAddresses,
    """
    ALTER TABLE marks ADD COLUMN writeSeq INTEGER NOT NULL DEFAULT 0;
    \(markWrites)
    DROP INDEX cueMessages_open;
    DROP INDEX cueMessages_answered;
    DROP INDEX cueMessages_setAside;
    DROP INDEX cueMessages_toDeliver;
    ALTER TABLE cueMessages DROP COLUMN choices;
    ALTER TABLE cueMessages DROP COLUMN answer;
    ALTER TABLE cueMessages DROP COLUMN answeredAt;
    ALTER TABLE cueMessages DROP COLUMN ask;
    ALTER TABLE cueMessages DROP COLUMN askAction;
    ALTER TABLE cueMessages DROP COLUMN askRule;
    ALTER TABLE cueMessages DROP COLUMN setAsideBy;
    \(toDeliverIndex)
    """,
  ]

  static let liveAddresses = "CREATE TABLE liveAddresses (sessionID TEXT PRIMARY KEY NOT NULL, url TEXT NOT NULL, found INTEGER NOT NULL, sentAt INTEGER NOT NULL) STRICT;"

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

  static let version = baseVersion + upgrades.count
}
