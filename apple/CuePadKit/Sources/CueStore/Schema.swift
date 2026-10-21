import CueText
import Foundation

/// 表分两类。
///
/// 同步表（由 CueSync 映射为 CKRecord，record type = 表名，recordName = id）：
/// projects、cards、sendRecords、attachments、piSessionStates、agentCatalogs、deliveryRequests、directoryBindings、piMessages、previews、accountQuotas、
/// cueMessages、cueLines、cueProfile、cueState、cueRead、macPresence、macAgents、sessionViewers。约束：
/// - 主键是 TEXT UUID（小写），由 Swift 侧生成；
/// - 每条记录有 `modifiedAt`（毫秒），供字段级合并与冲突判断；
/// - 软删除只有 `deletedAt`；
/// - 没有 FOREIGN KEY、UNIQUE：同步乱序送达记录，引用可能先于目标到达，
///   引用完整性由写入逻辑维护（同一事务内清理），同哈希附件的并发重复可容忍；
/// - 列只用 TEXT / INTEGER，能直接映射 CKRecord 字段。
///
/// 同步表里的本机列（不进 CKRecord，记录映射的列表里没有它们）：deliveryRequests.resultReceivedAt、cueToldAt（Cue 已知道没送到）；
/// piSessionStates、cards、deliveryRequests、piMessages 的 writeSeq（本机写入序号，见 `writeSeq`）。
///
/// 本机表（不同步）：piSessions、piProcesses、writeCounter、projectDirectories、syncRecords、syncState、searchIndex（FTS5，由触发器随同步表维护，可随时重建）、
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

  /// 能打开的最老结构版本（`upgrades` 的起点）：更早的库不升级、不打开（`schemaTooOld`）。
  /// 发出的版本把用户的库都升过了某一版，就把那一版及以前的步骤折进 `create`、起点挪到那一版：`create` 建的就是最新结构，
  /// 升级步骤只留还有库没跑过的。
  static let baseVersion = 66

  /// `upgrades[i]` 把结构版本 `baseVersion + i` 升到 `baseVersion + i + 1`；改结构时在末尾追加一步，同时更新 `create`
  /// （新库直接建成最新结构、不跑升级步骤：只改数据的一步在空库上无事可做）。
  /// 一步里任何会因数据冲突失败的语句（加唯一索引、NOT NULL、按假定的数据形状改写）都会让启动失败、库打不开：
  /// 要按别的设备已经同步来的、任意形状的数据写。
  static let upgrades: [Upgrade] = [
    // 67：同步元数据的系统字段压缩存（`SystemFields`），真实库从 65MB 降到约 10MB。原地改写的行仍各占一页，所以整表重建：
    // 一条 INSERT … SELECT 按行压缩，建好再补索引；腾出的页由升级后的整理还给磁盘（`reclaim`）
    Upgrade { db in
      try db.define("packSystemFields", SystemFields.pack)
      try db.exec(
        """
        ALTER TABLE syncRecords RENAME TO syncRecordsOld; DROP INDEX syncRecords_recordType; DROP INDEX syncRecords_pushed;
        \(syncRecordsTable)
        INSERT INTO syncRecords SELECT recordName, recordType, packSystemFields(systemFields), pushedModifiedAt, sentModifiedAt FROM syncRecordsOld;
        DROP TABLE syncRecordsOld;
        \(syncRecordsIndexes)
        """)
    },
    // 68：启动与每次会话、Cue 对话变化都要读的几处走索引（各自的理由见下面的定义）
    "DROP INDEX piSessionStates_state; \(stateIndex) \(launchTokenIndex) \(hostedIndex) \(toDeliverIndex)",
  ]

  /// 升级腾出了大量空页（如 67 把系统字段压小）时整理一遍，把它们还给磁盘：库不开自动整理，空页只等以后的写入复用，文件不会变小。
  /// 别的进程（命令行、扩展）正开着库时整理不了（忙），空页留着照样复用，不挡打开。
  static func reclaim(_ db: SQLite) throws {
    let free = try db.first("PRAGMA freelist_count") { $0.int(0) } ?? 0
    let total = try db.first("PRAGMA page_count") { $0.int(0) } ?? 0
    guard free * 4 > total else { return }
    try? db.exec("VACUUM")
  }

  /// 默认项目（`Project.defaultID`）的那一条：新库建好就有。修改时间是 0：各台设备离线各自建出的是同一版，
  /// 合并时用户改过的（名字、颜色、图标）总比它新，不会被一台新装的设备盖回"默认"。
  private static let defaultProject = """
    INSERT INTO projects (id, name, icon, color, isPinned, deletedAt, createdAt, modifiedAt, intro)
    VALUES ('\(Project.defaultID.uuidString.lowercased())', '默认', 'house', '#8A8A84', 0, NULL, 0, 0, NULL)
    ON CONFLICT(id) DO NOTHING;
    """

  /// 推导待推送（`CueStore.pendingSync`）只读每条记录的 id 与修改时间、同步元数据的记录名、类型与收下的修改时间：
  /// 覆盖索引让它不碰表本身——同步元数据每行带系统字段，会话消息、会话记录的行也大，真实库一次推导因此从 3.3 亿条指令降到 1 亿。
  private static func pendingIndexes(_ tables: [Table]) -> String {
    """
    \(syncRecordsIndexes)
    \(tables.map(modifiedIndex).joined(separator: "\n"))
    """
  }

  /// 同步元数据：每条记录服务器端的系统字段（压缩存，见 `SystemFields`）与服务器收下的修改时间（从没收下过为 NULL），以及本机交出去的那一版的修改时间
  /// （sentModifiedAt，见 `CueStore.noteSent`）。服务器收下过而行已不在数据表里的，就是要向服务器删除的（不需要墓碑表）。
  private static let syncRecordsTable = """
    CREATE TABLE syncRecords (
      recordName TEXT PRIMARY KEY NOT NULL, recordType TEXT NOT NULL, systemFields BLOB,
      pushedModifiedAt INTEGER, sentModifiedAt INTEGER
    ) STRICT;
    """
  private static let syncRecordsIndexes = """
    CREATE INDEX syncRecords_recordType ON syncRecords(recordType, pushedModifiedAt, recordName);
    CREATE INDEX syncRecords_pushed ON syncRecords(recordName, pushedModifiedAt);
    """

  private static func modifiedIndex(_ table: Table) -> String {
    "CREATE INDEX \(table.rawValue)_modified ON \(table.rawValue)(id, modifiedAt);"
  }
  /// 各台 Mac 跑过 Agent 的文件夹（`CueStore.sessionFolders`）：每次会话记录变化都重读，按 (Mac, 文件夹) 聚合只读这几列，
  /// 不碰带问答长文的会话记录本身（真实库四千多条，整表冷读约 75ms）。
  private static let folderIndex = """
    CREATE INDEX piSessionStates_folder ON piSessionStates(hostID, folder, stateSince, sessionID, projectID)
      WHERE \(CueStore.hasFolder);
    """
  /// 清理过期对话（`CueStore.prunePiMessages`，启动时一次）按会话取最后的时刻：只读索引，不逐条读消息正文（冷读约 190ms → 15ms）。
  private static let transcriptAgeIndex = "CREATE INDEX piMessages_sessionID_at ON piMessages(sessionID, at, createdAt);"
  /// 本机会话索引按 Agent 取、删（启动时对每家接入各一次）：表里存着检查点，整表扫一次约 35ms。表达式与查询同出 `CueStore.agentOf`。
  private static let agentIndex = "CREATE INDEX piSessions_agent ON piSessions(\(CueStore.agentOf));"
  /// Cue 还开着的提问（首屏读、每次 Cue 的对话变化重读）：部分索引只收这几条，条件与查询同出 `CueStore.openQuestion`（不一样就用不上）。
  /// Cue 页读到的对话之前问、之后答的提问（`CueStore.cueQuestionsAnswered`，每次 Cue 的对话变化重读）：提问只占对话的一小部分。
  private static let answeredIndex = "CREATE INDEX cueMessages_answered ON cueMessages(answeredAt) WHERE \(CueStore.answered);"
  private static let openQuestionIndex = "CREATE INDEX cueMessages_open ON cueMessages(createdAt) WHERE \(CueStore.openQuestion);"
  /// 你开口收起的提问（`CueStore.cueQuestionsSetAside`，每次把你的话交给 Cue 都读）：部分索引只收这几条，条件同出 `CueStore.setAside`。
  private static let setAsideIndex = "CREATE INDEX cueMessages_setAside ON cueMessages(createdAt) WHERE \(CueStore.setAside);"
  /// 待交给 Cue 的大脑的（`CueStore.cueMessagesToDeliver`，Cue 的对话每变一次都读）：部分索引只收这几条，条件同出 `CueStore.toDeliver`。
  /// 整表扫一次要读一千多条带正文的行。
  private static let toDeliverIndex = "CREATE INDEX cueMessages_toDeliver ON cueMessages(createdAt) WHERE \(CueStore.toDeliver);"
  /// 按状态取会话（结束的按项目各取最近几条、按项目计数，`CueStore.piSessionGroups`，会话列表每次变化都读）：带上项目与 id 只读索引，
  /// 不回表读带问答长文的会话记录（真实库四千多条结束的，冷读从约一千五百页降到一百多页）。
  private static let stateIndex = "CREATE INDEX piSessionStates_state ON piSessionStates(state, stateSince, projectID, id);"
  /// 开新会话的请求按认领标识对会话记录（认领、等认领、Cue 开出的会话，`CueStore.launchUnclaimed` 等）：没有它时每对一次都现建一份自动索引或整表扫，
  /// 真实库里启动时这几条占读库指令的大半。只有 CuePad 开的会话带标识。
  private static let launchTokenIndex = "CREATE INDEX piSessionStates_launchToken ON piSessionStates(launchToken) WHERE launchToken IS NOT NULL;"
  /// 这台 Mac 托管过的会话（`CueStore.hostedPiSessionIDs`，启动时没接入的每家各读一次、删索引时再读）：几千条记录里只有几十条，条件同出 `CueStore.hostedOrLaunched`。
  private static let hostedIndex = "CREATE INDEX piSessionStates_hosted ON piSessionStates(hostID, sessionID) WHERE \(CueStore.hostedOrLaunched);"

  /// 本机写入序号（`CueStore.lastWrite`）的计数器与盖序号的触发器：Cue 的变化按本机收到的先后分新旧，不按事件时刻（晚到的事件时刻可能早于上次醒来）。
  /// 构成 Cue 的变化的那几列真的变了（不只是被写了一遍）时，计数器加一、那一行记下它；本机写入与同步落库走的都是 INSERT / UPDATE，一处覆盖两条路。
  /// 会话记录（`sessionChanges`）、卡片（完成、上级、是不是任务）、Cue 发起的请求（状态）在改变时盖，对话里的消息在新增时盖。
  private static let writeSeq = """
    CREATE TABLE writeCounter (seq INTEGER NOT NULL) STRICT;
    INSERT INTO writeCounter (seq) VALUES (0);
    \(stamped("piSessionStates", when: sessionChanges))
    \(stamped("cards", when: ["completedAt", "parentID", "todoAt"]))
    \(stamped("deliveryRequests", when: ["status"]))
    \(stamped("piMessages", when: []))
    """

  /// `table`（已有 `writeSeq` 列）新增的行，或 `when` 里的列改了值的行，盖上计数器的下一个数。
  private static func stamped(_ table: String, when columns: [String]) -> String {
    let insert = "CREATE TRIGGER \(table)_writeSeq_insert AFTER INSERT ON \(table) BEGIN \(stamp(table)) END;"
    return columns.isEmpty ? insert : insert + "\n" + stampOnChange(table, columns)
  }

  /// 会话记录上构成 Cue 的变化的列：进入的状态与时刻，与最后一轮在会话文件里收尾的时刻（读到这一轮的回答时它变，变化随之就绪）。
  private static let sessionChanges = ["state", "stateSince", "answeredAt"]

  private static func stampOnChange(_ table: String, _ columns: [String]) -> String {
    let changed = columns.map { "old.\($0) IS NOT new.\($0)" }.joined(separator: " OR ")
    return "CREATE TRIGGER \(table)_writeSeq_update AFTER UPDATE OF \(columns.joined(separator: ", ")) ON \(table) WHEN \(changed) BEGIN \(stamp(table)) END;"
  }

  private static func stamp(_ table: String) -> String {
    "UPDATE writeCounter SET seq = seq + 1; UPDATE \(table) SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid;"
  }

  /// `PRAGMA user_version`：空库为 0，建好后为 `version`；旧于 `baseVersion` 的拒绝打开；其余旧的按 `upgrades` 就地升级；
  /// 比它新的是更新版本建的库，不打开。
  static let version = baseVersion + upgrades.count

  /// 新库的结构（`version` 那一版），与从 `baseVersion` 升上来的库表、列、索引、触发器一致；列的先后不同（早年的库加列都在表尾），
  /// 读写都按列名，不受影响。
  static let create = """
    CREATE TABLE projects (
      id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, icon TEXT, color TEXT NOT NULL,
      isPinned INTEGER NOT NULL, deletedAt INTEGER,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, intro TEXT
    ) STRICT;

    -- conflictOf：冲突副本指向原卡。todoAt 有值是任务（灵感为 NULL），parentID 是上级任务。
    -- formerSessionIDs：叶子以前用过的会话（换下来的仍属于它），记着的卡只占一小部分（部分索引）。
    CREATE TABLE cards (
      id TEXT PRIMARY KEY NOT NULL, projectID TEXT, body TEXT NOT NULL,
      isPinned INTEGER NOT NULL, variableValues TEXT NOT NULL, sortKey TEXT NOT NULL, conflictOf TEXT,
      deletedAt INTEGER, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL,
      parentID TEXT, todoAt INTEGER, startedAt INTEGER, completedAt INTEGER, piSessionID TEXT, archivedAt INTEGER,
      formerSessionIDs TEXT, writeSeq INTEGER NOT NULL DEFAULT 0
    ) STRICT;
    CREATE INDEX cards_projectID_sortKey ON cards(projectID, sortKey);
    CREATE INDEX cards_projectID_modifiedAt ON cards(projectID, modifiedAt);
    CREATE INDEX cards_parentID ON cards(parentID);
    CREATE INDEX cards_deletedAt ON cards(deletedAt) WHERE deletedAt IS NOT NULL;
    CREATE INDEX cards_todoAt ON cards(todoAt) WHERE todoAt IS NOT NULL;
    CREATE INDEX cards_piSessionID ON cards(piSessionID) WHERE piSessionID IS NOT NULL;
    CREATE INDEX cards_formerSessionIDs ON cards(id) WHERE formerSessionIDs IS NOT NULL;

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
      pendingTools TEXT, model TEXT, thinking TEXT, context TEXT, agent TEXT, catalogID TEXT, turnStartedAt INTEGER, answeredAt INTEGER,
      stateSince INTEGER NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, writeSeq INTEGER NOT NULL DEFAULT 0
    ) STRICT;
    CREATE INDEX piSessionStates_hostID ON piSessionStates(hostID);
    CREATE INDEX piSessionStates_sessionID ON piSessionStates(sessionID);
    \(stateIndex)
    \(launchTokenIndex)
    \(hostedIndex)
    CREATE INDEX piSessionStates_projectID ON piSessionStates(projectID, stateSince);
    -- 指向带模型的目录记录的只有在线会话，进程没了的只指向只有命令的那几份：回收没人用的目录时不必翻全部历史
    CREATE INDEX piSessionStates_catalogID ON piSessionStates(catalogID) WHERE catalogID IS NOT NULL;
    \(folderIndex)

    -- 会话可换的模型与斜杠命令（AgentCatalog）；id 由主机与内容算出，写下不改。
    CREATE TABLE agentCatalogs (id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, models TEXT, commands TEXT, modifiedAt INTEGER NOT NULL) STRICT;

    -- Agent 发到手机的预览。
    CREATE TABLE previews (
      id TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL, hash TEXT NOT NULL, name TEXT NOT NULL, title TEXT NOT NULL,
      byteCount INTEGER NOT NULL, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX previews_sessionID_createdAt ON previews(sessionID, createdAt);

    -- 订阅账号的用量：每个提供方一条（id 由提供方定），windows 是 JSON 数组。
    CREATE TABLE accountQuotas (
      id TEXT PRIMARY KEY NOT NULL, provider TEXT NOT NULL, hostID TEXT NOT NULL, windows TEXT NOT NULL,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE piMessages (
      id TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL, seq INTEGER NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL,
      at INTEGER NOT NULL, tools TEXT, roundStartedAt INTEGER, deliveryID TEXT,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, writeSeq INTEGER NOT NULL DEFAULT 0, question TEXT
    ) STRICT;
    CREATE INDEX piMessages_sessionID_seq ON piMessages(sessionID, seq);
    \(transcriptAgeIndex)

    -- 项目在哪台 Mac 上绑定了代码目录：每个 (projectID, hostID) 一条，只有目录末段名（完整路径在本机表 projectDirectories）。
    CREATE TABLE directoryBindings (
      id TEXT PRIMARY KEY NOT NULL, projectID TEXT NOT NULL, hostID TEXT NOT NULL,
      folder TEXT NOT NULL, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE deliveryRequests (
      id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL, targetName TEXT NOT NULL,
      targetRef TEXT, hostID TEXT NOT NULL, mode TEXT NOT NULL, cardID TEXT, status TEXT NOT NULL,
      resultDetail TEXT, handledBy TEXT, createdAt INTEGER NOT NULL, completedAt INTEGER, modifiedAt INTEGER NOT NULL,
      resultReceivedAt INTEGER, origin TEXT, cueToldAt INTEGER, writeSeq INTEGER NOT NULL DEFAULT 0
    ) STRICT;
    CREATE INDEX deliveryRequests_status ON deliveryRequests(status, createdAt);

    -- Pi 历史索引：checkpoint 是服务层的不透明字节（读取偏移与解析状态）。
    CREATE TABLE piSessions (
      id TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
      lastActivityAt INTEGER NOT NULL, checkpoint BLOB, agent TEXT
    ) STRICT;
    CREATE INDEX piSessions_cwd ON piSessions(cwd);
    \(agentIndex)

    -- 承载会话的进程：pid 与启动时刻（微秒），只在本机（PiProcess）。
    CREATE TABLE piProcesses (sessionID TEXT PRIMARY KEY NOT NULL, pid INTEGER NOT NULL, startedAt INTEGER NOT NULL) STRICT;

    -- 项目绑定的代码目录：路径因设备而异，只在本机。Pi 会话按 cwd 归入项目时用它。
    CREATE TABLE projectDirectories (
      projectID TEXT PRIMARY KEY NOT NULL, directory TEXT NOT NULL
    ) STRICT;

    \(syncRecordsTable)
    -- 同步的本机状态：同步区令牌（zoneToken）与上次同步的 iCloud 账号（account）。
    CREATE TABLE syncState (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL) STRICT;

    -- Cue 的对话（tools 是一轮的经过，ask 是提问的类别与范围，askAction、askRule 是它要做的动作与依据的规矩，askShots 是 Cue 点名要你看的图（提问的与做完的结果，`CueMessage.shots`），setAsideBy 是你开口收起它的那句话，wake 是 Cue 自己醒来的那一轮为什么醒）、记忆、设置（allows 是允许清单）与此刻在做什么（round 是在跑的那一轮）。
    CREATE TABLE cueMessages (
      id TEXT PRIMARY KEY NOT NULL, author TEXT NOT NULL, text TEXT NOT NULL, choices TEXT, urgent INTEGER NOT NULL,
      taskID TEXT, answer TEXT, answeredAt INTEGER, deliveredAt INTEGER, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL,
      notify TEXT, tools TEXT, ask TEXT, askAction TEXT, askRule TEXT, askShots TEXT, setAsideBy TEXT, wake TEXT
    ) STRICT;
    CREATE INDEX cueMessages_createdAt ON cueMessages(createdAt);
    \(openQuestionIndex)
    \(answeredIndex)
    \(setAsideIndex)
    \(toDeliverIndex)
    CREATE TABLE cueLines (
      id TEXT PRIMARY KEY NOT NULL, text TEXT NOT NULL, pinned INTEGER NOT NULL, source TEXT NOT NULL, remindAt INTEGER,
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, deletedAt INTEGER
    ) STRICT;
    CREATE INDEX cueLines_order ON cueLines(createdAt, id);
    CREATE INDEX cueLines_remindAt ON cueLines(remindAt) WHERE remindAt IS NOT NULL;
    CREATE TABLE cueProfile (
      id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, hostID TEXT, runtime TEXT NOT NULL, model TEXT, effort TEXT,
      enabledAt INTEGER, modifiedAt INTEGER NOT NULL, allows TEXT
    ) STRICT;
    -- lineIDs：区间里各行 id 的指纹，行序变了（别处同步来更早的行）摘要随之作废
    CREATE TABLE cueSummaries (
      lo INTEGER NOT NULL, hi INTEGER NOT NULL, text TEXT NOT NULL, lineIDs TEXT NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY (lo, hi)
    ) STRICT;
    CREATE TABLE cueState (
      id TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL, detail TEXT, modifiedAt INTEGER NOT NULL, round TEXT, context TEXT, leftToYou TEXT
    ) STRICT;
    CREATE TABLE cueRead (id TEXT PRIMARY KEY NOT NULL, modifiedAt INTEGER NOT NULL) STRICT;

    \(writeSeq)

    -- 每台 Mac 自己写、各端读：在线记录（Mac 在不在、Cue 在不在值班的唯一信号），能用的 Agent 与各家的模型。
    CREATE TABLE macPresence (id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, onlineUntil INTEGER NOT NULL, modifiedAt INTEGER NOT NULL) STRICT;
    CREATE TABLE macAgents (id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, agents TEXT, problems TEXT, modifiedAt INTEGER NOT NULL, name TEXT) STRICT;
    -- 每台设备自己写：此刻开着哪个会话、开没开着 Cue 页（会话停下时他在不在场的一半；提示到不到他）。
    CREATE TABLE sessionViewers (id TEXT PRIMARY KEY NOT NULL, device TEXT NOT NULL, sessionID TEXT, modifiedAt INTEGER NOT NULL, cue INTEGER) STRICT;

    -- trigram 分词：中文等无空格文本可子串匹配；LIKE 在其上对任意长度关键字都正确（3 字符以上走索引）。
    CREATE VIRTUAL TABLE searchIndex USING fts5(text, refID, kind UNINDEXED, tokenize = 'trigram');
    \(searchTriggers(table: "projects", column: "name", kind: "project"))
    \(searchTriggers(table: "cards", column: "body", kind: "card"))
    \(pendingIndexes(Table.synced))
    \(defaultProject)
    """

  /// 触发器对本地写入与将来同步的写入一视同仁，索引始终跟随数据。
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
