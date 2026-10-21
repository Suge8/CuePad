import CueText

extension Schema {
  /// 推导待推送（`CueStore.pendingSync`）只读每条记录的 id 与修改时间、同步元数据的记录名、类型与收下的修改时间：
  /// 覆盖索引让它不碰表本身——同步元数据每行带系统字段，会话消息、会话记录的行也大，真实库一次推导因此从 3.3 亿条指令降到 1 亿。
  static func pendingIndexes(_ tables: [Table]) -> String {
    """
    \(syncRecordsIndexes)
    \(tables.map(modifiedIndex).joined(separator: "\n"))
    """
  }

  private static func modifiedIndex(_ table: Table) -> String {
    "CREATE INDEX \(table.rawValue)_modified ON \(table.rawValue)(id, modifiedAt);"
  }
  /// 各台 Mac 跑过 Agent 的文件夹（`CueStore.sessionFolders`）：每次会话记录变化都重读，按 (Mac, 文件夹) 聚合只读这几列，
  /// 不碰带问答长文的会话记录本身（真实库四千多条，整表冷读约 75ms）。
  static let folderIndex = """
    CREATE INDEX piSessionStates_folder ON piSessionStates(hostID, folder, stateSince, sessionID, projectID)
      WHERE \(CueStore.hasFolder);
    """
  /// 清理过期对话（`CueStore.prunePiMessages`，启动时一次）按会话取最后的时刻：只读索引，不逐条读消息正文（冷读约 190ms → 15ms）。
  static let transcriptAgeIndex = "CREATE INDEX piMessages_sessionID_at ON piMessages(sessionID, at, createdAt);"
  /// 本机会话索引按 Agent 取、删（启动时对每家接入各一次）：表里存着检查点，整表扫一次约 35ms。表达式与查询同出 `CueStore.agentOf`。
  static let agentIndex = "CREATE INDEX piSessions_agent ON piSessions(\(CueStore.agentOf));"
  /// Cue 还开着的提问（首屏读、每次 Cue 的对话变化重读）：部分索引只收这几条，条件与查询同出 `CueStore.openQuestion`（不一样就用不上）。
  /// Cue 页读到的对话之前问、之后答的提问（`CueStore.cueQuestionsAnswered`，每次 Cue 的对话变化重读）：提问只占对话的一小部分。
  static let answeredIndex = "CREATE INDEX cueMessages_answered ON cueMessages(answeredAt) WHERE \(CueStore.answered);"
  static let openQuestionIndex = "CREATE INDEX cueMessages_open ON cueMessages(createdAt) WHERE \(CueStore.openQuestion);"
  /// 你开口收起的提问（`CueStore.cueQuestionsSetAside`，每次把你的话交给 Cue 都读）：部分索引只收这几条，条件同出 `CueStore.setAside`。
  static let setAsideIndex = "CREATE INDEX cueMessages_setAside ON cueMessages(createdAt) WHERE \(CueStore.setAside);"
  /// 待交给 Cue 的大脑的（`CueStore.cueMessagesToDeliver`，Cue 的对话每变一次都读）：部分索引只收这几条，条件同出 `CueStore.toDeliver`。
  /// 整表扫一次要读一千多条带正文的行。
  static let toDeliverIndex = "CREATE INDEX cueMessages_toDeliver ON cueMessages(createdAt) WHERE \(CueStore.toDeliver);"
  /// 按状态取会话（结束的按项目各取最近几条、按项目计数，`CueStore.piSessionPage`，会话列表每次变化都读）：带上项目与 id 只读索引，
  /// 不回表读带问答长文的会话记录（真实库四千多条结束的，冷读从约一千五百页降到一百多页）。
  static let stateIndex = "CREATE INDEX piSessionStates_state ON piSessionStates(state, stateSince, projectID, id);"
  /// 开新会话的请求按认领标识对会话记录（认领、等认领、Cue 开出的会话，`CueStore.launchUnclaimed` 等）：没有它时每对一次都现建一份自动索引或整表扫，
  /// 真实库里启动时这几条占读库指令的大半。只有 CuePad 开的会话带标识。
  static let launchTokenIndex = "CREATE INDEX piSessionStates_launchToken ON piSessionStates(launchToken) WHERE launchToken IS NOT NULL;"
  /// 这台 Mac 托管过的会话（`CueStore.hostedPiSessionIDs`，启动时没接入的每家各读一次、删索引时再读）：几千条记录里只有几十条，条件同出 `CueStore.hostedOrLaunched`。
  static let hostedIndex = "CREATE INDEX piSessionStates_hosted ON piSessionStates(hostID, sessionID) WHERE \(CueStore.hostedOrLaunched);"

  /// 本机写入序号（`CueStore.lastWrite`）的计数器与盖序号的触发器：Cue 的变化按本机收到的先后分新旧，不按事件时刻（晚到的事件时刻可能早于上次醒来）。
  /// 构成 Cue 的变化的那几列真的变了（不只是被写了一遍）时，计数器加一、那一行记下它；本机写入与同步落库走的都是 INSERT / UPDATE，一处覆盖两条路。
  /// 会话记录（`sessionChanges`）、卡片（完成、上级、是不是任务）、Cue 发起的请求（状态）新增时与这几列改变时盖。
  static let writeSeq = """
    CREATE TABLE writeCounter (seq INTEGER NOT NULL) STRICT;
    INSERT INTO writeCounter (seq) VALUES (0);
    \(stamped("piSessionStates", when: sessionChanges))
    \(stamped("cards", when: ["completedAt", "parentID", "todoAt"]))
    \(stamped("deliveryRequests", when: ["status"]))
    """

  /// `table`（已有 `writeSeq` 列）新增的行，或 `when` 里的列改了值的行，盖上计数器的下一个数。
  private static func stamped(_ table: String, when columns: [String]) -> String {
    let changed = columns.map { "old.\($0) IS NOT new.\($0)" }.joined(separator: " OR ")
    return """
      CREATE TRIGGER \(table)_writeSeq_insert AFTER INSERT ON \(table) BEGIN \(stamp(table)) END;
      CREATE TRIGGER \(table)_writeSeq_update AFTER UPDATE OF \(columns.joined(separator: ", ")) ON \(table) WHEN \(changed) BEGIN \(stamp(table)) END;
      """
  }

  /// 会话记录上构成 Cue 的变化的列：进入的状态与时刻，与最后一轮在会话文件里收尾的时刻（读到这一轮的回答时它变，变化随之就绪）。
  private static let sessionChanges = ["state", "stateSince", "answeredAt"]

  private static func stamp(_ table: String) -> String {
    "UPDATE writeCounter SET seq = seq + 1; UPDATE \(table) SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid;"
  }

  /// 触发器对本地写入与将来同步的写入一视同仁，索引始终跟随数据。
  static func searchTriggers(table: String, column: String, kind: String) -> String {
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
