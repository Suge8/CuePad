import Foundation

/// 表分两类。
///
/// 同步表（由 CKSyncEngine 映射为 CKRecord，record type = 表名，recordName = id）：
/// projects、cards、sendRecords、attachments、piSessionStates、deliveryRequests、directoryBindings、piMessages。约束：
/// - 主键是 TEXT UUID（小写），由 Swift 侧生成；
/// - 每条记录有 `modifiedAt`（毫秒），供字段级合并与冲突判断；
/// - 软删除只有 `deletedAt`；
/// - 没有 FOREIGN KEY、UNIQUE：CKSyncEngine 乱序送达记录，引用可能先于目标到达，
///   引用完整性由写入逻辑维护（同一事务内清理），同哈希附件的并发重复可容忍；
/// - 列只用 TEXT / INTEGER，能直接映射 CKRecord 字段。
///
/// 同步表里的本机列（不进 CKRecord）：deliveryRequests.resultReceivedAt。
///
/// 本机表（不同步）：piSessions、projectDirectories、syncRecords、syncState、searchIndex（FTS5，由触发器随同步表维护，可随时重建）。
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

  /// 能打开的最老结构版本（`upgrades` 的起点）：更早的库不升级、不打开。
  static let baseVersion = 17

  /// `upgrades[i]` 把结构版本 `baseVersion + i` 升到 `baseVersion + i + 1`；改结构时在末尾追加一步，同时更新 `create`。
  static let upgrades: [Upgrade] = []

  /// `PRAGMA user_version`：空库为 0，建好后为 `version`；旧于 `baseVersion` 的拒绝打开；其余旧的按 `upgrades` 就地升级；
  /// 比它新的是更新版本建的库，不打开。
  static let version = baseVersion + upgrades.count

  static let create = """
    CREATE TABLE projects (
      id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, icon TEXT, color TEXT NOT NULL,
      isPinned INTEGER NOT NULL, deletedAt INTEGER,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, intro TEXT
    ) STRICT;

    -- conflictOf：冲突副本指向原卡。todoAt 有值是任务（灵感为 NULL），parentID 是上级任务。
    CREATE TABLE cards (
      id TEXT PRIMARY KEY NOT NULL, projectID TEXT, body TEXT NOT NULL,
      isPinned INTEGER NOT NULL, variableValues TEXT NOT NULL, sortKey TEXT NOT NULL, conflictOf TEXT,
      deletedAt INTEGER, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL,
      parentID TEXT, todoAt INTEGER, startedAt INTEGER, completedAt INTEGER, piSessionID TEXT, archivedAt INTEGER
    ) STRICT;
    CREATE INDEX cards_projectID_sortKey ON cards(projectID, sortKey);
    CREATE INDEX cards_projectID_modifiedAt ON cards(projectID, modifiedAt);
    CREATE INDEX cards_parentID ON cards(parentID);

    CREATE TABLE sendRecords (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL,
      targetName TEXT NOT NULL, targetRef TEXT, cardID TEXT,
      sentAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX sendRecords_sentAt ON sendRecords(sentAt);
    CREATE INDEX sendRecords_cardID_sentAt ON sendRecords(cardID, sentAt);

    CREATE TABLE attachments (
      id TEXT PRIMARY KEY NOT NULL, hash TEXT NOT NULL, byteCount INTEGER NOT NULL, format TEXT NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX attachments_hash ON attachments(hash);

    -- Pi 会话状态（按会话一条）；notify 是明文通知标志，服务端订阅按它触发手机通知。
    CREATE TABLE piSessionStates (
      id TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL, hostID TEXT NOT NULL, title TEXT NOT NULL,
      projectID TEXT, state TEXT NOT NULL, detail TEXT, notify TEXT, folder TEXT,
      lastPrompt TEXT, lastReply TEXT, question TEXT, busySince INTEGER, launchToken TEXT, hosted INTEGER, subagents TEXT, pendingPrompt TEXT,
      model TEXT, thinking TEXT, models TEXT,
      stateSince INTEGER NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX piSessionStates_hostID ON piSessionStates(hostID);
    CREATE INDEX piSessionStates_state ON piSessionStates(state, stateSince);
    CREATE INDEX piSessionStates_projectID ON piSessionStates(projectID, stateSince);

    CREATE TABLE piMessages (
      id TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL, seq INTEGER NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL,
      at INTEGER NOT NULL, toolCount INTEGER NOT NULL, roundStartedAt INTEGER, deliveryID TEXT,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX piMessages_sessionID_seq ON piMessages(sessionID, seq);

    -- 项目在哪台 Mac 上绑定了代码目录：每个 (projectID, hostID) 一条，只有目录末段名（完整路径在本机表 projectDirectories）。
    CREATE TABLE directoryBindings (
      id TEXT PRIMARY KEY NOT NULL, projectID TEXT NOT NULL, hostID TEXT NOT NULL, hostName TEXT NOT NULL,
      folder TEXT NOT NULL, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE deliveryRequests (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL, targetName TEXT NOT NULL,
      targetRef TEXT, hostID TEXT NOT NULL, mode TEXT NOT NULL, cardID TEXT, status TEXT NOT NULL,
      resultDetail TEXT, handledBy TEXT, createdAt INTEGER NOT NULL, completedAt INTEGER, modifiedAt INTEGER NOT NULL,
      resultReceivedAt INTEGER
    ) STRICT;
    CREATE INDEX deliveryRequests_status ON deliveryRequests(status, createdAt);

    -- Pi 历史索引：checkpoint 是服务层的不透明字节（读取偏移与解析状态）。
    CREATE TABLE piSessions (
      id TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
      lastActivityAt INTEGER NOT NULL, checkpoint BLOB
    ) STRICT;
    CREATE INDEX piSessions_cwd ON piSessions(cwd);

    -- 项目绑定的代码目录：路径因设备而异，只在本机。Pi 会话按 cwd 归入项目时用它。
    CREATE TABLE projectDirectories (
      projectID TEXT PRIMARY KEY NOT NULL, directory TEXT NOT NULL
    ) STRICT;

    -- 同步元数据：每条记录服务器端的系统字段与已推送的修改时间。行已不在数据表里的，就是要向服务器删除的（不需要墓碑表）。
    CREATE TABLE syncRecords (
      recordName TEXT PRIMARY KEY NOT NULL, recordType TEXT NOT NULL, systemFields BLOB NOT NULL,
      pushedModifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX syncRecords_recordType ON syncRecords(recordType);
    CREATE TABLE syncState (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL) STRICT;

    -- trigram 分词：中文等无空格文本可子串匹配；LIKE 在其上对任意长度关键字都正确（3 字符以上走索引）。
    CREATE VIRTUAL TABLE searchIndex USING fts5(text, refID, kind UNINDEXED, tokenize = 'trigram');
    \(searchTriggers(table: "projects", column: "name", kind: "project"))
    \(searchTriggers(table: "cards", column: "body", kind: "card"))
    """

  /// 触发器对本地写入与将来同步引擎的写入一视同仁，索引始终跟随数据。
  private static func searchTriggers(table: String, column: String, kind: String) -> String {
    let remove = #"DELETE FROM searchIndex WHERE searchIndex MATCH 'refID: "' || old.id || '"';"#
    let add = """
      INSERT INTO searchIndex(text, refID, kind)
      SELECT new.\(column), new.id, '\(kind)' WHERE new.\(column) <> '';
      """
    return """
      CREATE TRIGGER searchIndex_\(table)_insert AFTER INSERT ON \(table) BEGIN \(add) END;
      CREATE TRIGGER searchIndex_\(table)_update AFTER UPDATE OF \(column) ON \(table) BEGIN \(remove) \(add) END;
      CREATE TRIGGER searchIndex_\(table)_delete AFTER DELETE ON \(table) BEGIN \(remove) END;
      """
  }
}
