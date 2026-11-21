import CueText

extension Schema {
  static func pendingIndexes(_ tables: [Table]) -> String {
    """
    \(syncRecordsIndexes)
    \(tables.map(modifiedIndex).joined(separator: "\n"))
    """
  }

  static let progressIndexes = """
    CREATE INDEX cards_projectID_progress ON cards(projectID, \(CueStore.cardProgress));
    CREATE INDEX piSessionStates_projectID_turn ON piSessionStates(projectID, \(CueStore.turnProgress));
    """

  static func modifiedIndex(_ table: Table) -> String {
    "CREATE INDEX \(table.rawValue)_modified ON \(table.rawValue)(id, modifiedAt);"
  }
  static let folderIndex = """
    CREATE INDEX piSessionStates_folder ON piSessionStates(hostID, folder, stateSince, sessionID, projectID)
      WHERE \(CueStore.hasFolder);
    """
  static let transcriptAgeIndex = "CREATE INDEX piMessages_sessionID_at ON piMessages(sessionID, at, createdAt);"
  static let taskOriginIndex = "CREATE INDEX piSessionStates_createdForTaskID ON piSessionStates(createdForTaskID) WHERE createdForTaskID IS NOT NULL;"
  static let agentIndex = "CREATE INDEX piSessions_agent ON piSessions(agent);"
  static let answeredIndex = "CREATE INDEX cueMessages_answered ON cueMessages(answeredAt) WHERE \(CueStore.answered);"
  static let openQuestionIndex = "CREATE INDEX cueMessages_open ON cueMessages(createdAt) WHERE \(CueStore.openQuestion);"
  static let setAsideIndex = "CREATE INDEX cueMessages_setAside ON cueMessages(createdAt) WHERE \(CueStore.setAside);"
  static let toDeliverIndex = "CREATE INDEX cueMessages_toDeliver ON cueMessages(createdAt) WHERE \(CueStore.toDeliver);"
  static let stateIndex = "CREATE INDEX piSessionStates_state ON piSessionStates(state, stateSince, projectID, id);"
  static let launchTokenIndex = "CREATE INDEX piSessionStates_launchToken ON piSessionStates(launchToken) WHERE launchToken IS NOT NULL;"
  static let hostedIndex = "CREATE INDEX piSessionStates_hosted ON piSessionStates(hostID, sessionID) WHERE \(CueStore.hostedOrLaunched);"

  static let writeSeq = """
    CREATE TABLE writeCounter (seq INTEGER NOT NULL) STRICT;
    INSERT INTO writeCounter (seq) VALUES (0);
    \(stamped("piSessionStates", when: sessionChanges))
    \(stamped("cards", when: ["completedAt", "parentID", "todoAt"]))
    \(stamped("deliveryRequests", when: ["status"]))
    \(cueMessageWrites)
    """

  private static let cueMessageWrites = """
    \(stamped("cueMessages", when: ["answeredRequests"]))
    CREATE INDEX cueMessages_writeSeq ON cueMessages(writeSeq);
    """

  private static func stamped(_ table: String, when columns: [String]) -> String {
    """
      CREATE TRIGGER \(table)_writeSeq_insert AFTER INSERT ON \(table) BEGIN \(stamp(table)) END;
      CREATE TRIGGER \(table)_writeSeq_update AFTER UPDATE OF \(columns.joined(separator: ", ")) ON \(table) WHEN \(changed(columns)) BEGIN \(stamp(table)) END;
      """
  }

  static let sessionChanges = ["state", "stateSince", "answeredAt", "bootID"]

  private static func changed(_ columns: [String]) -> String { columns.map { "old.\($0) IS NOT new.\($0)" }.joined(separator: " OR ") }

  private static func stamp(_ table: String) -> String {
    "UPDATE writeCounter SET seq = seq + 1; UPDATE \(table) SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid;"
  }

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
