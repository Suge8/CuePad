extension CueStore {
  static let cardVisible = """
    deletedAt IS NULL AND projectID IN (SELECT id FROM projects WHERE deletedAt IS NULL)
    """

  static let cardActive = "(\(cardVisible)) AND archivedAt IS NULL"

  static func taskOnBoard(_ alias: String? = nil) -> String {
    let c = alias.map { "\($0)." } ?? ""
    return """
      \(c)todoAt IS NOT NULL AND \(c)deletedAt IS NULL AND \(c)archivedAt IS NULL
        AND \(c)projectID NOT IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL)
      """
  }

  static let taskOpen = "completedAt IS NULL AND \(taskOnBoard())"

  static let taskDoneOnBoard = "completedAt IS NOT NULL AND \(taskOnBoard())"

  static let looseIdea = """
    todoAt IS NULL AND (parentID IS NULL OR parentID NOT IN (SELECT id FROM cards WHERE deletedAt IS NULL AND todoAt IS NOT NULL))
    """

  static let recentlyDone = "t.completedAt DESC, t.writeSeq DESC, t.id"

  static let notBlank = "TRIM(body, char(32, 9, 10, 13)) <> ''"
}
