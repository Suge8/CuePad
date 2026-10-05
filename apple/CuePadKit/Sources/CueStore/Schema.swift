import Foundation

/// 表分两类。
///
/// 同步表（由 CKSyncEngine 映射为 CKRecord，record type = 表名，recordName = id）：
/// projects、cards、tasks、sendRecords、attachments、piSessionStates、deliveryRequests、directoryBindings。约束：
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
/// 同步表只能加表或加可空列，不改已有列：其他版本的设备仍按旧字段读写同一批记录。
enum Schema {
  /// `PRAGMA user_version`：空库为 0，建好后为 `version`；比它旧的按 `upgrades` 就地升级；比它新的是更新版本建的库，不打开。
  static let version = 6

  /// `upgrades[i]` 把结构版本 i + 1 升到 i + 2。新库直接用 `create`（已是最新结构）。
  static let upgrades = [
    // Pi 会话状态带上工作目录的文件夹名：手机上没有工作目录，副行靠它写出"在哪"
    "ALTER TABLE piSessionStates ADD COLUMN folder TEXT;",
    // 会话近况：手机打开会话时看最后的提问、回答与待确认的问题
    """
    ALTER TABLE piSessionStates ADD COLUMN lastPrompt TEXT; ALTER TABLE piSessionStates ADD COLUMN lastReply TEXT;
    ALTER TABLE piSessionStates ADD COLUMN question TEXT;
    """,
    // 连续处理的计时基准：细状态切换不重置"已运行"
    "ALTER TABLE piSessionStates ADD COLUMN busySince INTEGER;",
    // CuePad 发起的新会话带着发起方的标识，发起方据此认领
    "ALTER TABLE piSessionStates ADD COLUMN launchToken TEXT;",
    // 历史会话上手机后几千条：界面按范围（在线/已结束）读；项目在哪台 Mac 上绑定了目录同步给手机
    """
    CREATE INDEX piSessionStates_state ON piSessionStates(state, stateSince);
    CREATE TABLE directoryBindings (
      id TEXT PRIMARY KEY NOT NULL, projectID TEXT NOT NULL, hostID TEXT NOT NULL, hostName TEXT NOT NULL,
      folder TEXT NOT NULL, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    """,
  ]

  static let create = """
    CREATE TABLE projects (
      id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, icon TEXT, color TEXT NOT NULL,
      sortKey TEXT NOT NULL, isPinned INTEGER NOT NULL, goalCardID TEXT, deletedAt INTEGER,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;

    -- conflictOf：冲突副本指向原卡。
    CREATE TABLE cards (
      id TEXT PRIMARY KEY NOT NULL, projectID TEXT, body TEXT NOT NULL, numbering TEXT NOT NULL,
      isPinned INTEGER NOT NULL, variableValues TEXT NOT NULL, sortKey TEXT NOT NULL, conflictOf TEXT,
      deletedAt INTEGER, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX cards_projectID_sortKey ON cards(projectID, sortKey);

    CREATE TABLE tasks (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, projectID TEXT, sortKey TEXT NOT NULL,
      completedAt INTEGER, piSessionID TEXT, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX tasks_projectID ON tasks(projectID);

    CREATE TABLE sendRecords (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL,
      targetName TEXT NOT NULL, targetRef TEXT, cardID TEXT, taskID TEXT,
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
      lastPrompt TEXT, lastReply TEXT, question TEXT, busySince INTEGER, launchToken TEXT,
      stateSince INTEGER NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX piSessionStates_hostID ON piSessionStates(hostID);
    CREATE INDEX piSessionStates_state ON piSessionStates(state, stateSince);

    -- 项目在哪台 Mac 上绑定了代码目录：每个 (projectID, hostID) 一条，只有目录末段名（完整路径在本机表 projectDirectories）。
    CREATE TABLE directoryBindings (
      id TEXT PRIMARY KEY NOT NULL, projectID TEXT NOT NULL, hostID TEXT NOT NULL, hostName TEXT NOT NULL,
      folder TEXT NOT NULL, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE deliveryRequests (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL, targetName TEXT NOT NULL,
      targetRef TEXT, hostID TEXT NOT NULL, mode TEXT NOT NULL, cardID TEXT, taskID TEXT, status TEXT NOT NULL,
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
