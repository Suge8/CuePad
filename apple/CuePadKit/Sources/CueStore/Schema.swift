import CueText
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

  /// `PRAGMA user_version`：空库为 0，建好后为 `version`；比它旧的按 `upgrades` 就地升级；比它新的是更新版本建的库，不打开。
  static let version = upgrades.count + 1

  /// `upgrades[i]` 把结构版本 i + 1 升到 i + 2。新库直接用 `create`（已是最新结构）。
  static let upgrades: [Upgrade] = [
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
    // Mac 在后台托管的会话、结构化的子代理列表
    "ALTER TABLE piSessionStates ADD COLUMN hosted INTEGER; ALTER TABLE piSessionStates ADD COLUMN subagents TEXT;",
    // 项目只按"置顶、再按最近活动"排（不再有手动排序键）；卡片编号下线；任务多了"开始做"的时间（三态）
    """
    ALTER TABLE projects DROP COLUMN sortKey; ALTER TABLE cards DROP COLUMN numbering;
    ALTER TABLE tasks ADD COLUMN startedAt INTEGER;
    CREATE INDEX cards_projectID_modifiedAt ON cards(projectID, modifiedAt);
    CREATE INDEX tasks_projectID_modifiedAt ON tasks(projectID, modifiedAt);
    CREATE INDEX piSessionStates_projectID ON piSessionStates(projectID, stateSince);
    """,
    // 进行中的提问与最近一轮已做完的问答分开
    "ALTER TABLE piSessionStates ADD COLUMN pendingPrompt TEXT;",
    // 会话的完整对话：一条消息一条记录
    "\(piMessagesTable)",
    // 子任务：任务挂在上级任务下（最多三级）
    "ALTER TABLE tasks ADD COLUMN parentID TEXT; CREATE INDEX tasks_parentID ON tasks(parentID);",
    // 会话当前的模型、思考强度与可选模型（手机上选）
    """
    ALTER TABLE piSessionStates ADD COLUMN model TEXT; ALTER TABLE piSessionStates ADD COLUMN thinking TEXT;
    ALTER TABLE piSessionStates ADD COLUMN models TEXT;
    """,
    // 灵感与任务合成一种记录：任务并进 cards（id 暂时不变，见下一步），目标卡改为项目的一句话介绍
    Upgrade(unifyCardsAndTasks),
    // 迁移来的任务卡片沿用了任务的 id，服务器上同名的 tasks 记录不能改类型，永远上传不了：换成由旧 id 算出的新 id
    Upgrade(renameMigratedTasks),
    // 交给 Agent 时一并带上的灵感：发送记录与投送请求明确记下它们（任务完成圈里灵感那一段只看这个）
    "ALTER TABLE sendRecords ADD COLUMN partIDs TEXT; ALTER TABLE deliveryRequests ADD COLUMN partIDs TEXT;",
  ]

  private static let cardsTreeIndex = "CREATE INDEX cards_parentID ON cards(parentID);"

  /// 任务原样插成"要做"的卡片（要做时间取任务的创建时间）；发送记录与投送请求的任务引用并进卡片引用（id 相同）；
  /// 目标卡第一行（去掉"目标："）成为项目介绍、目标卡留作普通灵感；去掉 tasks 表与它的同步元数据——服务器上的旧任务记录
  /// 不删（退役类型，客户端跳过），这样还没升级的设备之间照常同步。
  private static func unifyCardsAndTasks(_ db: SQLite) throws {
    try db.exec("""
      ALTER TABLE cards ADD COLUMN parentID TEXT; ALTER TABLE cards ADD COLUMN todoAt INTEGER;
      ALTER TABLE cards ADD COLUMN startedAt INTEGER; ALTER TABLE cards ADD COLUMN completedAt INTEGER;
      ALTER TABLE cards ADD COLUMN piSessionID TEXT;
      \(cardsTreeIndex)
      INSERT INTO cards (id, projectID, body, isPinned, variableValues, sortKey, deletedAt, createdAt, modifiedAt, conflictOf,
        parentID, todoAt, startedAt, completedAt, piSessionID)
      SELECT id, projectID, content, 0, '{}', sortKey, NULL, createdAt, modifiedAt, NULL,
        parentID, createdAt, startedAt, completedAt, piSessionID FROM tasks;
      UPDATE sendRecords SET cardID = taskID WHERE cardID IS NULL AND taskID IS NOT NULL;
      ALTER TABLE sendRecords DROP COLUMN taskID;
      UPDATE deliveryRequests SET cardID = taskID WHERE cardID IS NULL AND taskID IS NOT NULL;
      ALTER TABLE deliveryRequests DROP COLUMN taskID;
      ALTER TABLE projects ADD COLUMN intro TEXT;
      DELETE FROM syncRecords WHERE recordType = 'tasks';
      DROP TABLE tasks;
      """)
    let goals = try db.query("SELECT p.id, c.body FROM projects p JOIN cards c ON c.id = p.goalCardID") { ($0.text(0), $0.text(1)) }
    for (project, body) in goals {
      let intro = CueSummary(body).title.replacing(/^(目标|Goal)\s*[:：]\s*/.ignoresCase(), with: "")
      try db.run("UPDATE projects SET intro = ? WHERE id = ?", [intro.isEmpty ? nil : intro, project])
    }
    try db.exec("ALTER TABLE projects DROP COLUMN goalCardID;")
  }

  /// 还没上传过的"要做"卡片（上一步从任务迁来的，没有同步元数据）换新 id：指向它们的上级、冲突原卡、发送记录与投送请求跟着改。
  /// 新 id 只由旧 id 算出，不论各设备先后升级都得到同一个；改了引用的行顺带登记为待上传，别的设备才跟上。
  /// 没迁移过的库里没有这样的卡，什么都不做。
  /// 别的设备可能已经升级、把同一个任务以新 id 同步到了本机（本机还停在上一步）：新 id 已存在时不能再改名（主键冲突会让升级失败、
  /// App 启动即崩溃），同一个任务留较新的一份——本机较新就把内容并到新 id 那条上（它的同步元数据留着，改动自然待上传）。
  /// 整行"较新者胜"，不做字段级合并：与同步里同一条记录的冲突规则一致（正文冲突才另存副本，迁来的任务没有这种情形）。
  private static func renameMigratedTasks(_ db: SQLite) throws {
    let stale = try db.query("SELECT id FROM cards WHERE todoAt IS NOT NULL AND id NOT IN (SELECT recordName FROM syncRecords)") { $0.text(0) }
    let now = Date.stamp
    for old in stale {
      let new = DeterministicID.uuid("task-card/\(old)").uuidString.lowercased()
      if try db.first("SELECT 1 FROM cards WHERE id = ?", [new], { _ in true }) == true {
        try db.run(
          """
          UPDATE cards SET projectID = o.projectID, body = o.body, isPinned = o.isPinned, variableValues = o.variableValues,
            sortKey = o.sortKey, conflictOf = o.conflictOf, deletedAt = o.deletedAt, createdAt = o.createdAt, modifiedAt = o.modifiedAt,
            parentID = o.parentID, todoAt = o.todoAt, startedAt = o.startedAt, completedAt = o.completedAt, piSessionID = o.piSessionID
          FROM cards o WHERE o.id = ?1 AND cards.id = ?2 AND o.modifiedAt > cards.modifiedAt
          """, [old, new])
        try db.run("DELETE FROM cards WHERE id = ?", [old])
      } else {
        try db.run("UPDATE cards SET id = ? WHERE id = ?", [new, old])
        try db.run(#"UPDATE searchIndex SET refID = ? WHERE searchIndex MATCH 'refID: "' || ? || '"'"#, [new, old])
      }
      for (table, column) in [("cards", "parentID"), ("cards", "conflictOf"), ("sendRecords", "cardID"), ("deliveryRequests", "cardID")] {
        try db.run("UPDATE \(table) SET \(column) = ?, modifiedAt = ? WHERE \(column) = ?", [new, now, old])
      }
    }
  }

  private static let piMessagesTable = """
    CREATE TABLE piMessages (
      id TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL, seq INTEGER NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL,
      at INTEGER NOT NULL, toolCount INTEGER NOT NULL, roundStartedAt INTEGER, deliveryID TEXT,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX piMessages_sessionID_seq ON piMessages(sessionID, seq);
    """


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
      parentID TEXT, todoAt INTEGER, startedAt INTEGER, completedAt INTEGER, piSessionID TEXT
    ) STRICT;
    CREATE INDEX cards_projectID_sortKey ON cards(projectID, sortKey);
    CREATE INDEX cards_projectID_modifiedAt ON cards(projectID, modifiedAt);
    \(cardsTreeIndex)

    CREATE TABLE sendRecords (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL,
      targetName TEXT NOT NULL, targetRef TEXT, cardID TEXT,
      sentAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, partIDs TEXT
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

    \(piMessagesTable)

    -- 项目在哪台 Mac 上绑定了代码目录：每个 (projectID, hostID) 一条，只有目录末段名（完整路径在本机表 projectDirectories）。
    CREATE TABLE directoryBindings (
      id TEXT PRIMARY KEY NOT NULL, projectID TEXT NOT NULL, hostID TEXT NOT NULL, hostName TEXT NOT NULL,
      folder TEXT NOT NULL, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE deliveryRequests (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL, targetName TEXT NOT NULL,
      targetRef TEXT, hostID TEXT NOT NULL, mode TEXT NOT NULL, cardID TEXT, status TEXT NOT NULL,
      resultDetail TEXT, handledBy TEXT, createdAt INTEGER NOT NULL, completedAt INTEGER, modifiedAt INTEGER NOT NULL,
      resultReceivedAt INTEGER, partIDs TEXT
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
