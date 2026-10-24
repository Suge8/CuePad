extension CueStore {
  /// 卡片可见：自身未删除，且所属项目在库里、未删除（项目还没同步到的先不显示）。
  static let cardVisible = """
    deletedAt IS NULL AND projectID IN (SELECT id FROM projects WHERE deletedAt IS NULL)
    """

  /// 在列表里：可见且没归档（归档的只在"归档"里，搜索照样搜得到）。
  static let cardActive = "(\(cardVisible)) AND archivedAt IS NULL"

  /// 散放的灵感：不是任务，也没挂在一个看得见的任务下（上级没到、在回收站的按散放看待）。
  static let looseIdea = """
    todoAt IS NULL AND (parentID IS NULL OR parentID NOT IN (SELECT id FROM cards WHERE deletedAt IS NULL AND todoAt IS NOT NULL))
    """

  /// 列得出来的任务（`t` 是任务表，`p` 是它左连接的项目表）：要做、没删除、没归档，且所属项目没删除（还没同步到的项目照列，同 `taskProjectOrder`）。
  /// `tasks` 与 `taskCounts` 共用。
  static let visibleTask = "t.todoAt IS NOT NULL AND t.deletedAt IS NULL AND t.archivedAt IS NULL AND p.deletedAt IS NULL"

  /// 做完的任务（`t`）最近的在前：完成时刻相同（同一毫秒，或别的设备同步来时刻一样）的，本机后写下完成的在前（`writeSeq` 随 completedAt 变而盖），
  /// 不落到按 id 这种与先后无关的次序上——"刚做完"那一件、已完成那一列与 Cue 看的最近做完都按它。
  static let recentlyDone = "t.completedAt DESC, t.writeSeq DESC, t.id"

  /// 正文不是空白（与 `Card.isBlank` 同一条规则）。
  static let notBlank = "TRIM(body, char(32, 9, 10, 13)) <> ''"
}
