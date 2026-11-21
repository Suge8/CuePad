import Foundation

extension CueStore {
  static let taskSessionEvents = """
    CREATE TEMP TABLE taskSessionEvents (id TEXT PRIMARY KEY NOT NULL);
    CREATE TEMP TRIGGER taskSessionCardInserted AFTER INSERT ON main.cards
    WHEN NEW.todoAt IS NOT NULL
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.id); END;
    CREATE TEMP TRIGGER taskSessionCardClosed AFTER UPDATE OF completedAt, archivedAt, deletedAt ON main.cards
    WHEN NEW.todoAt IS NOT NULL AND OLD.completedAt IS NULL AND (
      NEW.completedAt IS NOT NULL OR (OLD.archivedAt IS NULL AND NEW.archivedAt IS NOT NULL)
      OR (OLD.deletedAt IS NULL AND NEW.deletedAt IS NOT NULL))
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.id); END;
    CREATE TEMP TRIGGER taskSessionStructureChanged AFTER UPDATE OF parentID, projectID, sortKey ON main.cards
    WHEN NEW.todoAt IS NOT NULL AND (OLD.parentID IS NOT NEW.parentID OR OLD.projectID IS NOT NEW.projectID OR OLD.sortKey IS NOT NEW.sortKey)
    BEGIN
      INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.id);
      INSERT OR IGNORE INTO taskSessionEvents SELECT OLD.parentID WHERE OLD.parentID IS NOT NULL;
    END;
    CREATE TEMP TRIGGER taskSessionProjectInserted AFTER INSERT ON main.projects
    WHEN NEW.deletedAt IS NOT NULL
    BEGIN
      INSERT OR IGNORE INTO taskSessionEvents SELECT id FROM cards
        WHERE projectID = NEW.id AND todoAt IS NOT NULL AND completedAt IS NULL;
    END;
    CREATE TEMP TRIGGER taskSessionProjectClosed AFTER UPDATE OF deletedAt ON main.projects
    WHEN OLD.deletedAt IS NULL AND NEW.deletedAt IS NOT NULL
    BEGIN
      INSERT OR IGNORE INTO taskSessionEvents SELECT id FROM cards
        WHERE projectID = NEW.id AND todoAt IS NOT NULL AND completedAt IS NULL;
    END;
    CREATE TEMP TRIGGER taskSessionSourceInserted AFTER INSERT ON main.piSessionStates
    WHEN NEW.createdForTaskID IS NOT NULL
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.createdForTaskID); END;
    CREATE TEMP TRIGGER taskSessionSourceChanged AFTER UPDATE OF createdForTaskID, hosted, agent ON main.piSessionStates
    WHEN NEW.createdForTaskID IS NOT NULL AND (
      OLD.createdForTaskID IS NOT NEW.createdForTaskID OR OLD.hosted IS NOT NEW.hosted OR OLD.agent IS NOT NEW.agent)
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.createdForTaskID); END;
    CREATE TEMP TRIGGER sessionUseReleased AFTER UPDATE OF status, mode, targetRef ON main.deliveryRequests
    WHEN OLD.targetRef IS NOT NULL AND OLD.mode IN (\(sqlList(DeliveryMode.toSession))) AND OLD.status IN (\(DeliveryStatus.openSQL))
      AND (NEW.status NOT IN (\(DeliveryStatus.openSQL)) OR NEW.mode NOT IN (\(sqlList(DeliveryMode.toSession))) OR OLD.targetRef IS NOT NEW.targetRef)
    BEGIN
      \(releasedHold)
    END;
    CREATE TEMP TRIGGER sessionUseRemoved AFTER DELETE ON main.deliveryRequests
    WHEN OLD.targetRef IS NOT NULL AND OLD.mode IN (\(sqlList(DeliveryMode.toSession))) AND OLD.status IN (\(DeliveryStatus.openSQL))
    BEGIN
      \(releasedHold)
    END;
    """

  private static let releasedHold = """
    INSERT OR IGNORE INTO taskSessionEvents SELECT s.createdForTaskID FROM piSessionStates s
      WHERE s.sessionID = OLD.targetRef AND s.createdForTaskID IS NOT NULL AND EXISTS (
        SELECT 1 FROM cards c WHERE (c.id = s.createdForTaskID OR c.piSessionID = s.sessionID)
          AND MIN(COALESCE(c.completedAt, \(Int64.max)), COALESCE(c.archivedAt, \(Int64.max)), COALESCE(c.deletedAt, \(Int64.max)),
            COALESCE((SELECT deletedAt FROM projects WHERE id = c.projectID), \(Int64.max))) >= OLD.createdAt);
    """

  func reconcileTaskSessionEvents() throws {
    let tasks = try db.query("SELECT id FROM taskSessionEvents") { $0.uuid(0) }
    for task in tasks { try endUnusedSessions(of: task, cue: false) }
    try db.run("DELETE FROM taskSessionEvents")
  }
}
