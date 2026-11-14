extension CueStore {
  static let cardVisible = """
    deletedAt IS NULL AND projectID IN (SELECT id FROM projects WHERE deletedAt IS NULL)
    """

  static let cardActive = "(\(cardVisible)) AND archivedAt IS NULL"

  /// 还在看板上的任务（含子任务、含做完的；`alias` 是卡片表的别名，nil 时不带）：要做、没删、没归档、项目没进回收站。任务“还活着”只有这一条：
  /// 列表、计数、会话的主人、会话有没有人用都按它。项目还没同步到的照算（不同于 `cardVisible`）：先到的任务照列，它的会话也不因项目晚到就没了主人、被当成没人用而结束。
  static func taskOnBoard(_ alias: String? = nil) -> String {
    let c = alias.map { "\($0)." } ?? ""
    return """
      \(c)todoAt IS NOT NULL AND \(c)deletedAt IS NULL AND \(c)archivedAt IS NULL
        AND \(c)projectID NOT IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL)
      """
  }

  /// 看板上没做完的（`taskOnBoard`）：它绑着的会话才算有人在用（`sessionInUse`、`isLoose`）。
  static let taskOpen = "completedAt IS NULL AND \(taskOnBoard())"

  static let taskDoneOnBoard = "completedAt IS NOT NULL AND \(taskOnBoard())"

  /// 散放的灵感：不是任务，也没挂在一个看得见的任务下（上级没到、在回收站的按散放看待）。
  static let looseIdea = """
    todoAt IS NULL AND (parentID IS NULL OR parentID NOT IN (SELECT id FROM cards WHERE deletedAt IS NULL AND todoAt IS NOT NULL))
    """

  /// 做完的任务（`t`）最近的在前：完成时刻相同（同一毫秒，或别的设备同步来时刻一样）的，本机后写下完成的在前（`writeSeq` 随 completedAt 变而盖），
  /// 不落到按 id 这种与先后无关的次序上——"刚做完"那一件、已完成那一列与 Cue 看的最近做完都按它。
  static let recentlyDone = "t.completedAt DESC, t.writeSeq DESC, t.id"

  static let notBlank = "TRIM(body, char(32, 9, 10, 13)) <> ''"
}
