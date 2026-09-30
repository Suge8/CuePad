import Foundation

/// 表分两类。
///
/// 同步表（阶段 3 由 CKSyncEngine 映射为 CKRecord，record type = 表名，recordName = id）：
/// projects、cards、tags、cardTags、tasks、sendRecords、attachments、piSessionStates、deliveryRequests、probes。约束：
/// - 主键是 TEXT UUID（小写），由 Swift 侧生成；
/// - 每条记录有 `modifiedAt`（毫秒），供字段级合并与冲突判断；
/// - 软删除只有 `deletedAt`；
/// - 没有 FOREIGN KEY、UNIQUE：CKSyncEngine 乱序送达记录，引用可能先于目标到达，
///   引用完整性由写入逻辑维护（同一事务内清理），同名标签、同哈希附件的并发重复可容忍；
/// - 列只用 TEXT / INTEGER，能直接映射 CKRecord 字段。
///
/// 本机表（不同步）：piSessions、projectDirectories、syncRecords、syncState、searchIndex（FTS5，由触发器随同步表维护，可随时重建）。
///
/// 之后的迁移只能加表或加可空列，不改已有列。
enum Schema {
    /// 依次执行，`PRAGMA user_version` 记录已执行个数。
  static let migrations: [String] = [v1, v2, v3, v4, v5]

  /// 阶段 3 第一档：Pi 会话状态（按会话一条）、投送请求、延迟探针记录，均为同步表。
  private static let v5 = """
    CREATE TABLE piSessionStates (
      id TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL, hostID TEXT NOT NULL, title TEXT NOT NULL,
      projectID TEXT, state TEXT NOT NULL, detail TEXT, stateSince INTEGER NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX piSessionStates_hostID ON piSessionStates(hostID);
    CREATE TABLE deliveryRequests (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL, targetName TEXT NOT NULL,
      targetRef TEXT, hostID TEXT, mode TEXT NOT NULL, cardID TEXT, taskID TEXT, status TEXT NOT NULL,
      resultDetail TEXT, handledBy TEXT, createdAt INTEGER NOT NULL, completedAt INTEGER, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX deliveryRequests_status ON deliveryRequests(status, createdAt);
    CREATE TABLE probes (
      id TEXT PRIMARY KEY NOT NULL, run TEXT NOT NULL, seq INTEGER NOT NULL, kind TEXT NOT NULL, origin TEXT NOT NULL,
      sentAt INTEGER NOT NULL, peerFetchStartedAt INTEGER, peerAppliedAt INTEGER, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX probes_run ON probes(run, seq);
    """

  /// 同步：冲突副本指向原卡；本机同步元数据（每条记录服务器端的系统字段与已推送的修改时间）与引擎状态。
  /// 元数据行同时是"服务器上有"的记录：行已不在数据表里的，就是要向服务器删除的（不需要墓碑表）。
  private static let v4 = """
    ALTER TABLE cards ADD COLUMN conflictOf TEXT;
    CREATE TABLE syncRecords (
      recordName TEXT PRIMARY KEY NOT NULL, recordType TEXT NOT NULL, systemFields BLOB NOT NULL,
      pushedModifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX syncRecords_recordType ON syncRecords(recordType);
    CREATE TABLE syncState (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL) STRICT;
    """

  /// Pi 历史索引的检查点（服务层的不透明字节，含读取偏移与分支树）替代单独的读取偏移列。
  /// 旧偏移随列删除，已有会话重新索引。
  private static let v3 = """
    ALTER TABLE piSessions ADD COLUMN checkpoint BLOB;
    ALTER TABLE piSessions DROP COLUMN readOffset;
    """

  /// 项目目标卡；发送记录按卡片查最近发送时间。
  private static let v2 = """
    ALTER TABLE projects ADD COLUMN goalCardID TEXT;
    CREATE INDEX sendRecords_cardID_sentAt ON sendRecords(cardID, sentAt);
    """

  private static let v1 = """
    CREATE TABLE projects (
      id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, icon TEXT, color TEXT NOT NULL,
      sortKey TEXT NOT NULL, isPinned INTEGER NOT NULL, deletedAt INTEGER,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE cards (
      id TEXT PRIMARY KEY NOT NULL, projectID TEXT, body TEXT NOT NULL, numbering TEXT NOT NULL,
      isFavorite INTEGER NOT NULL, variableValues TEXT NOT NULL, sortKey TEXT NOT NULL,
      deletedAt INTEGER, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX cards_projectID_sortKey ON cards(projectID, sortKey);

    CREATE TABLE tags (
      id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, color TEXT,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX tags_name ON tags(name);

    CREATE TABLE cardTags (
      id TEXT PRIMARY KEY NOT NULL, cardID TEXT NOT NULL, tagID TEXT NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX cardTags_cardID ON cardTags(cardID);
    CREATE INDEX cardTags_tagID ON cardTags(tagID);

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

    CREATE TABLE attachments (
      id TEXT PRIMARY KEY NOT NULL, hash TEXT NOT NULL, byteCount INTEGER NOT NULL, format TEXT NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX attachments_hash ON attachments(hash);

    CREATE TABLE piSessions (
      id TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
      lastActivityAt INTEGER NOT NULL, readOffset INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX piSessions_cwd ON piSessions(cwd);

    -- 项目绑定的代码目录：路径因设备而异，只在本机。Pi 会话按 cwd 归入项目时用它。
    CREATE TABLE projectDirectories (
      projectID TEXT PRIMARY KEY NOT NULL, directory TEXT NOT NULL
    ) STRICT;

    -- trigram 分词：中文等无空格文本可子串匹配；LIKE 在其上对任意长度关键字都正确（3 字符以上走索引）。
    CREATE VIRTUAL TABLE searchIndex USING fts5(text, refID, kind UNINDEXED, tokenize = 'trigram');
    \(searchTriggers(table: "projects", column: "name", kind: "project"))
    \(searchTriggers(table: "cards", column: "body", kind: "card"))
    \(searchTriggers(table: "tags", column: "name", kind: "tag"))
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
