import Foundation

/// 表分两类。
///
/// 同步表（由 CKSyncEngine 映射为 CKRecord，record type = 表名，recordName = id）：
/// projects、cards、sendRecords、attachments、piSessionStates、deliveryRequests、directoryBindings、piMessages、previews、accountQuotas、
/// cueMessages、cueLines、cueProfile、cueState。约束：
/// - 主键是 TEXT UUID（小写），由 Swift 侧生成；
/// - 每条记录有 `modifiedAt`（毫秒），供字段级合并与冲突判断；
/// - 软删除只有 `deletedAt`；
/// - 没有 FOREIGN KEY、UNIQUE：CKSyncEngine 乱序送达记录，引用可能先于目标到达，
///   引用完整性由写入逻辑维护（同一事务内清理），同哈希附件的并发重复可容忍；
/// - 列只用 TEXT / INTEGER，能直接映射 CKRecord 字段。
///
/// 同步表里的本机列（不进 CKRecord）：deliveryRequests.resultReceivedAt。
///
/// 本机表（不同步）：piSessions、projectDirectories、syncRecords、syncSent、syncState、searchIndex（FTS5，由触发器随同步表维护，可随时重建）、
/// cueSummaries（Cue 记忆的摘要缓存，可随时丢弃重建）。
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
  /// 一步里任何会因数据冲突失败的语句（加唯一索引、NOT NULL、按假定的数据形状改写）都会让启动失败、库打不开：
  /// 要按别的设备已经同步来的、任意形状的数据写。
  static let upgrades: [Upgrade] = [
    // 18：会话记录加上下文余量与斜杠命令清单
    "ALTER TABLE piSessionStates ADD COLUMN context TEXT; ALTER TABLE piSessionStates ADD COLUMN commands TEXT;",
    // 19：Agent 发到手机的预览
    Upgrade(stringLiteral: previews),
    // 20：对话里每轮回答带工具活动摘要（替换只有个数的 toolCount）；会话文件的检查点作废，下次启动从头读一遍，补出旧对话的摘要
    "ALTER TABLE piMessages ADD COLUMN tools TEXT; ALTER TABLE piMessages DROP COLUMN toolCount; UPDATE piSessions SET checkpoint = NULL;",
    // 21：会话相关写入按 sessionID 找状态记录；回收站按 deletedAt 数个数、列条目（部分索引，活着的卡不进）
    """
    CREATE INDEX piSessionStates_sessionID ON piSessionStates(sessionID);
    CREATE INDEX cards_deletedAt ON cards(deletedAt) WHERE deletedAt IS NOT NULL;
    """,
    // 22：任务、交给了会话的卡只占卡片的一小部分：列任务、数任务、找进行中的任务与交给的会话不必逐张翻全部卡片（一张一页）
    """
    CREATE INDEX cards_todoAt ON cards(todoAt) WHERE todoAt IS NOT NULL;
    CREATE INDEX cards_piSessionID ON cards(piSessionID) WHERE piSessionID IS NOT NULL;
    """,
    // 23：工具活动的各类计数改为失败的也算在内（与清单的行同一口径，`Tools.failed` 下线）；已存对话里的是旧口径，
    // 会话文件的检查点作废，下次启动从头读一遍，所有消息统一成新口径
    "UPDATE piSessions SET checkpoint = NULL;",
    // 24：本机交给过服务器、结果还没落账的版本整行（见 `syncSent`）
    Upgrade(stringLiteral: syncSent),
    // 25：任务最多两级，提示词不算一级。旧规则下第 3 级的任务（含回收站里的，恢复后同样超限）改挂到上级的上级，与 `CardLinks.repairs` 同一规则；
    // 旧规则最深就是第 3 级，一步够。modifiedAt 必须变大，改动才会同步出去
    Upgrade { db in
      try db.run(
        """
        UPDATE cards SET parentID = (SELECT p.parentID FROM cards p WHERE p.id = cards.parentID), modifiedAt = MAX(modifiedAt + 1, ?)
        WHERE todoAt IS NOT NULL AND parentID IN (
          SELECT p.id FROM cards p JOIN cards g ON g.id = p.parentID WHERE p.deletedAt IS NULL AND g.deletedAt IS NULL)
        """, [Date.stamp])
    },
    // 26：提示词送达即用掉（`PromptConsumption`）。旧库里已经发出去的提示词同样删掉：任务下的灵感（非资料、没进回收站），
    // 记着交给的会话（发给会话、开新会话认领后），或有成功的发送请求；还有在路上或失败的请求的留着（没送到的可重发）。
    // 删的是行：同步表的删除由下次对账发现（`pendingDeletes`），不另记墓碑。图片文件不在这里回收：发出去的话的发送记录快照仍引用它们。
    Upgrade { db in
      let delivered = try db.query(
        """
        SELECT c.id FROM cards c WHERE \(CueStore.isPrompt("c")) AND c.deletedAt IS NULL
          AND (c.piSessionID IS NOT NULL
            OR EXISTS (SELECT 1 FROM deliveryRequests r WHERE r.cardID = c.id AND r.status = 'succeeded' AND \(CueStore.delivers("r"))))
          AND NOT EXISTS (SELECT 1 FROM deliveryRequests r WHERE r.cardID = c.id AND r.status IN ('pending', 'executing', 'failed'))
        """
      ) { $0.uuid(0) }
      _ = try CueStore.consumePrompts(delivered, in: db)
    },
    // 27：任务的正文只有标题。旧任务的第二行起（一句说明）按设为任务的规则（`CueLines.split`）拆成它的第一条提示词：不带会话与发送记录，
    // 说明从没发给过 Agent。回收站与归档里的任务一并处理；modifiedAt 变大，改动才会同步出去
    Upgrade { db in
      let now = Date.stamp
      let tasks = try db.query("SELECT id, modifiedAt FROM cards WHERE todoAt IS NOT NULL AND instr(body, char(10)) > 0") {
        (id: $0.uuid(0), modifiedAt: $0.date(1))
      }
      for (id, modifiedAt) in tasks {
        _ = try CueStore.splitPrompt(db, task: id, at: max(now, modifiedAt.addingTimeInterval(0.001)), carryingHandoff: false)
      }
    },
    // 28：任务 → 步骤 → 会话。草稿（提示词）与会话只在叶子（没有步骤的任务）上，一个叶子最多一条草稿（`CardLinks`）。
    // 有步骤的任务下的提示词移到第一个没完成的步骤（没有就第一个步骤），它记着的会话也交给那个步骤（它已有会话的就丢弃上级的），
    // 一个叶子有多条提示词的按顺序并成一条：整库按远端收敛同一条规则（`CardLinks.repairs`）算一遍。modifiedAt 变大，改动才会同步出去
    Upgrade { db in
      let links = try CardLinks(db)
      try CueStore.apply(links.repairs(touching: Set(links.links.keys)), in: db, at: Date.stamp)
    },
    // 29：对话里你的消息改用正文格式（文字加图片引用），去掉 Pi 附给模型的图片说明；会话文件的检查点作废，下次启动从头读一遍，已存的消息跟着更新、补出图片
    "UPDATE piSessions SET checkpoint = NULL;",
    // 30：订阅账号的用量（每个提供方一条，Mac 写）
    Upgrade(stringLiteral: accountQuotas),
    // 31：会话记录与历史索引记下是哪个 Agent 的会话（Pi 之外接入 Claude Code、Codex、OpenCode）；旧行没有，是 Pi
    "ALTER TABLE piSessionStates ADD COLUMN agent TEXT; ALTER TABLE piSessions ADD COLUMN agent TEXT;",
    // 32：总控 Agent Cue：任务由谁跟进、请求来自谁（发送记录也记下送出它的请求与来源：请求清理后对话仍认得出 Cue 说的话），
    // Cue 的对话、记忆、设置与记忆摘要缓存
    Upgrade(stringLiteral: """
      ALTER TABLE cards ADD COLUMN cueFollows INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE deliveryRequests ADD COLUMN origin TEXT;
      ALTER TABLE sendRecords ADD COLUMN deliveryID TEXT;
      ALTER TABLE sendRecords ADD COLUMN origin TEXT;
      CREATE INDEX sendRecords_deliveryID ON sendRecords(deliveryID) WHERE deliveryID IS NOT NULL;
      \(cue)
      """),
    // 33：Cue 的验收由消息上的标记认（写入时定下），不再按选项文字猜
    Upgrade(stringLiteral: cueAcceptance),
    // 34：叶子记下以前用过的会话（换下来的会话仍属于它）；记着的卡只占一小部分（部分索引）
    Upgrade(stringLiteral: formerSessions),
    // 35：Cue 此刻在做什么（值班的 Mac 写，各端读）
    Upgrade(stringLiteral: cueState),
  ]

  /// 34 加的列与索引：建新库时跟在 `cueAcceptance` 之后。
  private static let formerSessions = """
    ALTER TABLE cards ADD COLUMN formerSessionIDs TEXT;
    CREATE INDEX cards_formerSessionIDs ON cards(id) WHERE formerSessionIDs IS NOT NULL;
    """

  private static let cueState = "CREATE TABLE cueState (id TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL, detail TEXT, modifiedAt INTEGER NOT NULL) STRICT;"

  /// 33 加的列：建新库时跟在 `cue` 之后（`cue` 是 32 建的样子，升级 32 也用它）。
  private static let cueAcceptance = "ALTER TABLE cueMessages ADD COLUMN acceptance INTEGER NOT NULL DEFAULT 0;"

  private static let accountQuotas = """
    CREATE TABLE accountQuotas (
      id TEXT PRIMARY KEY NOT NULL, provider TEXT NOT NULL, hostID TEXT NOT NULL, windows TEXT NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    """

  /// Cue 的表与"只有顶层任务能由 Cue 跟进"的守卫：卡片挂到别的任务下、改回灵感时 `cueFollows` 归零（本机写入与远端同步一视同仁）。
  private static let cue = """
    CREATE TABLE cueMessages (
      id TEXT PRIMARY KEY NOT NULL, author TEXT NOT NULL, text TEXT NOT NULL, choices TEXT, urgent INTEGER NOT NULL,
      taskID TEXT, answer TEXT, answeredAt INTEGER, deliveredAt INTEGER, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL,
      notify TEXT
    ) STRICT;
    CREATE INDEX cueMessages_createdAt ON cueMessages(createdAt);
    CREATE TABLE cueLines (
      id TEXT PRIMARY KEY NOT NULL, text TEXT NOT NULL, pinned INTEGER NOT NULL, source TEXT NOT NULL, remindAt INTEGER,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, deletedAt INTEGER
    ) STRICT;
    CREATE INDEX cueLines_order ON cueLines(createdAt, id);
    CREATE INDEX cueLines_remindAt ON cueLines(remindAt) WHERE remindAt IS NOT NULL;
    CREATE TABLE cueProfile (
      id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, hostID TEXT, runtime TEXT NOT NULL, model TEXT, effort TEXT,
      enabledAt INTEGER, modifiedAt INTEGER NOT NULL
    ) STRICT;
    -- lineIDs：区间里各行 id 的指纹，行序变了（别处同步来更早的行）摘要随之作废
    CREATE TABLE cueSummaries (
      lo INTEGER NOT NULL, hi INTEGER NOT NULL, text TEXT NOT NULL, lineIDs TEXT NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY (lo, hi)
    ) STRICT;
    CREATE TRIGGER cards_cueFollows_insert AFTER INSERT ON cards
      WHEN new.cueFollows <> 0 AND (new.parentID IS NOT NULL OR new.todoAt IS NULL)
      BEGIN UPDATE cards SET cueFollows = 0 WHERE id = new.id; END;
    CREATE TRIGGER cards_cueFollows_update AFTER UPDATE OF parentID, todoAt, cueFollows ON cards
      WHEN new.cueFollows <> 0 AND (new.parentID IS NOT NULL OR new.todoAt IS NULL)
      BEGIN UPDATE cards SET cueFollows = 0 WHERE id = new.id; END;
    """

  private static let syncSent = """
    CREATE TABLE syncSent (recordName TEXT NOT NULL, modifiedAt INTEGER NOT NULL, row BLOB NOT NULL, PRIMARY KEY (recordName, modifiedAt)) STRICT, WITHOUT ROWID;
    """

  private static let previews = """
    CREATE TABLE previews (
      id TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL, hash TEXT NOT NULL, name TEXT NOT NULL, title TEXT NOT NULL,
      byteCount INTEGER NOT NULL, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX previews_sessionID_createdAt ON previews(sessionID, createdAt);
    """

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
      parentID TEXT, todoAt INTEGER, startedAt INTEGER, completedAt INTEGER, piSessionID TEXT, archivedAt INTEGER,
      cueFollows INTEGER NOT NULL DEFAULT 0
    ) STRICT;
    CREATE INDEX cards_projectID_sortKey ON cards(projectID, sortKey);
    CREATE INDEX cards_projectID_modifiedAt ON cards(projectID, modifiedAt);
    CREATE INDEX cards_parentID ON cards(parentID);
    CREATE INDEX cards_deletedAt ON cards(deletedAt) WHERE deletedAt IS NOT NULL;
    CREATE INDEX cards_todoAt ON cards(todoAt) WHERE todoAt IS NOT NULL;
    CREATE INDEX cards_piSessionID ON cards(piSessionID) WHERE piSessionID IS NOT NULL;

    CREATE TABLE sendRecords (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL,
      targetName TEXT NOT NULL, targetRef TEXT, cardID TEXT,
      sentAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, deliveryID TEXT, origin TEXT
    ) STRICT;
    CREATE INDEX sendRecords_sentAt ON sendRecords(sentAt);
    CREATE INDEX sendRecords_cardID_sentAt ON sendRecords(cardID, sentAt);
    CREATE INDEX sendRecords_deliveryID ON sendRecords(deliveryID) WHERE deliveryID IS NOT NULL;

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
      model TEXT, thinking TEXT, models TEXT, context TEXT, commands TEXT, agent TEXT,
      stateSince INTEGER NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX piSessionStates_hostID ON piSessionStates(hostID);
    CREATE INDEX piSessionStates_sessionID ON piSessionStates(sessionID);
    CREATE INDEX piSessionStates_state ON piSessionStates(state, stateSince);
    CREATE INDEX piSessionStates_projectID ON piSessionStates(projectID, stateSince);

    \(previews)

    -- 订阅账号的用量：每个提供方一条（id 由提供方定），windows 是 JSON 数组。
    \(accountQuotas)

    CREATE TABLE piMessages (
      id TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL, seq INTEGER NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL,
      at INTEGER NOT NULL, tools TEXT, roundStartedAt INTEGER, deliveryID TEXT,
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
      resultReceivedAt INTEGER, origin TEXT
    ) STRICT;
    CREATE INDEX deliveryRequests_status ON deliveryRequests(status, createdAt);

    -- Pi 历史索引：checkpoint 是服务层的不透明字节（读取偏移与解析状态）。
    CREATE TABLE piSessions (
      id TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
      lastActivityAt INTEGER NOT NULL, checkpoint BLOB, agent TEXT
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
    -- 本机交给过服务器、结果还没落账的版本（整行，JSON）：这一版经拉取回到本机是自己的回声，不是别的设备的编辑；
    -- 结果回来时按它记账（上传的记录只带改动的字段，不能读回来）。落账（pushedModifiedAt 推进到它或更新）时清掉；落账之后的回声由 pushedModifiedAt 认出。
    \(syncSent)
    CREATE TABLE syncState (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL) STRICT;

    \(cue)
    \(cueAcceptance)
    \(formerSessions)
    \(cueState)

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
