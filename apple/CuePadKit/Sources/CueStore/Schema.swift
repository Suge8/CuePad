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
  /// 能打开的最老结构版本（`upgrades` 的起点）：更早的库不升级、不打开（`schemaTooOld`），也没有就地重建的入口。
  /// 只有作者自己的设备在用：起点可以挪到这些设备的库都已升过的那一版，却不能高于各平台最新一个 `mac/`、`ios/` 发布标签那时的结构（`lint_schema.py`）。
  /// 98 是 mac/2611132301 与 ios/2611132255。挪起点时把那一版及以前的步骤折进 `create`（它建的就是最新结构），给更早设备留的兼容一并删掉。
  static let baseVersion = 98

  /// 最低对端版本（CueSync 的 `PeerFloor`）：更早的设备停下收发、提示更新。只在旧版照新写法读写会做错事时抬到那一版——把新写法误读成别的意思、
  /// 写回时盖掉新字段、读不出就卡住同步；新加的表、字段与句式旧版只是不认（照旧字段显示、跳过读不出的），不抬：一抬，旧设备在更新前什么都发不出去。
  /// 抬的那一版先发 iOS、TestFlight 处理完再发 Mac：Mac 经 Sparkle 几分钟就装上，反过来发，苹果处理 iOS 的那段时间里手机停下收发。与 `baseVersion` 各定各的。
  /// 93：旧端会把晚到投送重新关联，也会误结束纯关联的托管会话；自动结束请求须由新端复核创建来源。
  static let peerFloor = 93

  /// `upgrades[i]` 把结构版本 `baseVersion + i` 升到 `baseVersion + i + 1`，同一个事务里执行；改结构时在末尾追加一步，同时更新 `create`
  /// （新库直接建成最新结构、不跑升级步骤：只改数据的一步在空库上无事可做；两者一致由测试的 `SchemaUpgradeTests` 守住）。
  /// 一步里任何会因数据冲突失败的语句（加唯一索引、NOT NULL、按假定的数据形状改写）都会让启动失败、库打不开：
  /// 要按别的设备已经同步来的、任意形状的数据写。
  static let upgrades = [
    // 99：会话记录记下开这一轮的那句话（`SessionState.turnOpener`）；已有的空着，下一句交出时补上
    "ALTER TABLE piSessionStates ADD COLUMN turnDelivery TEXT; ALTER TABLE piSessionStates ADD COLUMN turnByCue INTEGER;",
    // 100：你恢复使用的会话不再随任务结束（`SessionState.restoredAt`）；升级前恢复过的没有记录，照旧按任务收尾
    "ALTER TABLE piSessionStates ADD COLUMN restoredAt INTEGER;",
    // 101：你的注意（`Mark`）各记一行：Cue 页读到哪并进来（读到的位置不搬：只差你最后一句之后的几条再算一次新），会话看到哪从各台本机偏好搬上同步
    """
    DROP TABLE cueRead;
    DELETE FROM syncRecords WHERE recordType = 'cueRead';
    CREATE TABLE marks (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, subject TEXT NOT NULL, modifiedAt INTEGER NOT NULL) STRICT;
    CREATE INDEX marks_kind ON marks(kind, subject, modifiedAt);
    \(Schema.modifiedIndex(.marks))
    """,
  ]

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
