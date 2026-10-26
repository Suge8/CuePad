import CueText
import Foundation

extension Schema {
  /// 默认项目（`Project.defaultID`）的那一条：新库建好就有。修改时间是 0：各台设备离线各自建出的是同一版，
  /// 合并时用户改过的（名字、颜色、图标）总比它新，不会被一台新装的设备盖回"默认"。
  private static let defaultProject = """
    INSERT INTO projects (id, name, icon, color, isPinned, deletedAt, createdAt, modifiedAt, intro)
    VALUES ('\(Project.defaultID.uuidString.lowercased())', '\(Project.defaultName)', 'house', '#8A8A84', 0, NULL, 0, 0, NULL)
    ON CONFLICT(id) DO NOTHING;
    """

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
      createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, question TEXT, shownText TEXT
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
      failure TEXT, handledBy TEXT, createdAt INTEGER NOT NULL, completedAt INTEGER, modifiedAt INTEGER NOT NULL,
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

    -- Cue 的对话（tools 是一轮的经过，ask 是提问的类别与范围，askAction、askRule 是它要做的动作与依据的规矩，askShots 是 Cue 点名要你看的图（提问的与做完的结果，`CueMessage.shots`），setAsideBy 是你开口收起它的那句话，wake 是 Cue 自己醒来的那一轮为什么醒）、记忆、设置与此刻在做什么（round 是在跑的那一轮）。
    CREATE TABLE cueMessages (
      id TEXT PRIMARY KEY NOT NULL, author TEXT NOT NULL, text TEXT NOT NULL, choices TEXT, urgent INTEGER NOT NULL,
      taskID TEXT, answer TEXT, answeredAt INTEGER, deliveredAt INTEGER, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL,
      notify TEXT, tools TEXT, ask TEXT, askAction TEXT, askRule TEXT, askShots TEXT, setAsideBy TEXT, wake TEXT, places TEXT, shownText TEXT
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
      enabledAt INTEGER, modifiedAt INTEGER NOT NULL
    ) STRICT;
    -- lineIDs：区间里各行 id 的指纹，行序变了（别处同步来更早的行）摘要随之作废
    CREATE TABLE cueSummaries (
      lo INTEGER NOT NULL, hi INTEGER NOT NULL, text TEXT NOT NULL, lineIDs TEXT NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY (lo, hi)
    ) STRICT;
    CREATE TABLE cueState (
      id TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL, detail TEXT, modifiedAt INTEGER NOT NULL, round TEXT, context TEXT, leftToYou TEXT, step TEXT
    ) STRICT;
    CREATE TABLE cueRead (id TEXT PRIMARY KEY NOT NULL, modifiedAt INTEGER NOT NULL) STRICT;

    \(writeSeq)

    -- 每台 Mac 自己写、各端读：在线记录（Mac 在不在、Cue 在不在值班的唯一信号），能用的 Agent 与各家的模型。
    CREATE TABLE macPresence (id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, onlineUntil INTEGER NOT NULL, modifiedAt INTEGER NOT NULL) STRICT;
    CREATE TABLE macAgents (id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, agents TEXT, problems TEXT, modifiedAt INTEGER NOT NULL, name TEXT) STRICT;
    -- 每台设备自己写：此刻开着哪个会话、开没开着 Cue 页、他最近一次来到这台的时刻（会话停下时他在不在场的一半；提示到不到他）。
    CREATE TABLE sessionViewers (
      id TEXT PRIMARY KEY NOT NULL, device TEXT NOT NULL, sessionID TEXT, modifiedAt INTEGER NOT NULL, cue INTEGER, arrivedAt INTEGER
    ) STRICT;

    -- trigram 分词：中文等无空格文本可子串匹配；LIKE 在其上对任意长度关键字都正确（3 字符以上走索引）。
    CREATE VIRTUAL TABLE searchIndex USING fts5(text, refID, kind UNINDEXED, tokenize = 'trigram');
    \(searchTriggers(table: "projects", column: "name", kind: "project"))
    \(searchTriggers(table: "cards", column: "body", kind: "card"))
    \(pendingIndexes(Table.synced))
    \(defaultProject)
    """
}
