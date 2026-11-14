extension FrozenSchema {
  /// 结构 77 的新库（a76f711ae 的 `Schema.create`，由那时的代码建库后导出）。
  static let v77 = #"""
CREATE TABLE projects (
  id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, icon TEXT, color TEXT NOT NULL,
  isPinned INTEGER NOT NULL, deletedAt INTEGER,
  createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, intro TEXT
) STRICT;
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
CREATE INDEX piSessionStates_state ON piSessionStates(state, stateSince, projectID, id);
CREATE INDEX piSessionStates_launchToken ON piSessionStates(launchToken) WHERE launchToken IS NOT NULL;
CREATE INDEX piSessionStates_hosted ON piSessionStates(hostID, sessionID) WHERE (hosted = 1 OR launchToken IS NOT NULL);
CREATE INDEX piSessionStates_projectID ON piSessionStates(projectID, stateSince);
CREATE INDEX piSessionStates_catalogID ON piSessionStates(catalogID) WHERE catalogID IS NOT NULL;
CREATE INDEX piSessionStates_folder ON piSessionStates(hostID, folder, stateSince, sessionID, projectID)
  WHERE folder IS NOT NULL AND folder != '';
CREATE TABLE agentCatalogs (id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, models TEXT, commands TEXT, modifiedAt INTEGER NOT NULL) STRICT;
CREATE TABLE previews (
  id TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL, hash TEXT NOT NULL, name TEXT NOT NULL, title TEXT NOT NULL,
  byteCount INTEGER NOT NULL, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
) STRICT;
CREATE INDEX previews_sessionID_createdAt ON previews(sessionID, createdAt);
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
CREATE INDEX piMessages_sessionID_at ON piMessages(sessionID, at, createdAt);
CREATE TABLE directoryBindings (
  id TEXT PRIMARY KEY NOT NULL, projectID TEXT NOT NULL, hostID TEXT NOT NULL,
  folder TEXT NOT NULL, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL
) STRICT;
CREATE TABLE deliveryRequests (
  id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, targetKind TEXT NOT NULL, targetName TEXT NOT NULL,
  targetRef TEXT, hostID TEXT NOT NULL, mode TEXT NOT NULL, cardID TEXT, status TEXT NOT NULL,
  failure TEXT, handledBy TEXT, createdAt INTEGER NOT NULL, completedAt INTEGER, modifiedAt INTEGER NOT NULL,
  resultReceivedAt INTEGER, origin TEXT, cueToldAt INTEGER, writeSeq INTEGER NOT NULL DEFAULT 0, serverAt INTEGER
) STRICT;
CREATE INDEX deliveryRequests_status ON deliveryRequests(status, createdAt);
CREATE TABLE piSessions (
  id TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
  lastActivityAt INTEGER NOT NULL, checkpoint BLOB, agent TEXT
) STRICT;
CREATE INDEX piSessions_cwd ON piSessions(cwd);
CREATE INDEX piSessions_agent ON piSessions(COALESCE(agent, 'pi'));
CREATE TABLE piProcesses (sessionID TEXT PRIMARY KEY NOT NULL, pid INTEGER NOT NULL, startedAt INTEGER NOT NULL) STRICT;
CREATE TABLE projectDirectories (
  projectID TEXT PRIMARY KEY NOT NULL, directory TEXT NOT NULL
) STRICT;
CREATE TABLE syncRecords (
  recordName TEXT PRIMARY KEY NOT NULL, recordType TEXT NOT NULL, systemFields BLOB,
  pushedModifiedAt INTEGER, sentModifiedAt INTEGER
) STRICT;
CREATE TABLE syncState (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL) STRICT;
CREATE TABLE cueMessages (
  id TEXT PRIMARY KEY NOT NULL, author TEXT NOT NULL, text TEXT NOT NULL, choices TEXT, urgent INTEGER NOT NULL,
  taskID TEXT, answer TEXT, answeredAt INTEGER, deliveredAt INTEGER, createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL,
  notify TEXT, tools TEXT, ask TEXT, askAction TEXT, askRule TEXT, askShots TEXT, setAsideBy TEXT, wake TEXT, places TEXT, shownText TEXT
) STRICT;
CREATE INDEX cueMessages_createdAt ON cueMessages(createdAt);
CREATE INDEX cueMessages_open ON cueMessages(createdAt) WHERE author = 'cue' AND choices IS NOT NULL AND answeredAt IS NULL;
CREATE INDEX cueMessages_answered ON cueMessages(answeredAt) WHERE choices IS NOT NULL AND answer IS NOT NULL;
CREATE INDEX cueMessages_setAside ON cueMessages(createdAt) WHERE setAsideBy IS NOT NULL;
CREATE INDEX cueMessages_toDeliver ON cueMessages(createdAt) WHERE ((author = 'you' AND deliveredAt IS NULL)
  OR (author = 'cue' AND answer IS NOT NULL AND (deliveredAt IS NULL OR deliveredAt < answeredAt)));
CREATE TABLE cueLines (
  id TEXT PRIMARY KEY NOT NULL, text TEXT NOT NULL, pinned INTEGER NOT NULL, source TEXT NOT NULL, remindAt INTEGER,
  createdAt INTEGER NOT NULL, modifiedAt INTEGER NOT NULL, deletedAt INTEGER, repeats TEXT, taskID TEXT
) STRICT;
CREATE INDEX cueLines_order ON cueLines(createdAt, id);
CREATE INDEX cueLines_remindAt ON cueLines(remindAt) WHERE remindAt IS NOT NULL;
CREATE TABLE cueProfile (
  id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, hostID TEXT, runtime TEXT NOT NULL, model TEXT, effort TEXT,
  enabledAt INTEGER, modifiedAt INTEGER NOT NULL
) STRICT;
CREATE TABLE cueSummaries (
  lo INTEGER NOT NULL, hi INTEGER NOT NULL, text TEXT NOT NULL, lineIDs TEXT NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY (lo, hi)
) STRICT;
CREATE TABLE cueState (
  id TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL, detail TEXT, modifiedAt INTEGER NOT NULL, round TEXT, context TEXT, leftToYou TEXT, step TEXT
) STRICT;
CREATE TABLE cueRead (id TEXT PRIMARY KEY NOT NULL, modifiedAt INTEGER NOT NULL) STRICT;
CREATE TABLE writeCounter (seq INTEGER NOT NULL) STRICT;
CREATE TRIGGER piSessionStates_writeSeq_insert AFTER INSERT ON piSessionStates BEGIN UPDATE writeCounter SET seq = seq + 1; UPDATE piSessionStates SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid; END;
CREATE TRIGGER piSessionStates_writeSeq_update AFTER UPDATE OF state, stateSince, answeredAt ON piSessionStates WHEN old.state IS NOT new.state OR old.stateSince IS NOT new.stateSince OR old.answeredAt IS NOT new.answeredAt BEGIN UPDATE writeCounter SET seq = seq + 1; UPDATE piSessionStates SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid; END;
CREATE TRIGGER cards_writeSeq_insert AFTER INSERT ON cards BEGIN UPDATE writeCounter SET seq = seq + 1; UPDATE cards SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid; END;
CREATE TRIGGER cards_writeSeq_update AFTER UPDATE OF completedAt, parentID, todoAt ON cards WHEN old.completedAt IS NOT new.completedAt OR old.parentID IS NOT new.parentID OR old.todoAt IS NOT new.todoAt BEGIN UPDATE writeCounter SET seq = seq + 1; UPDATE cards SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid; END;
CREATE TRIGGER deliveryRequests_writeSeq_insert AFTER INSERT ON deliveryRequests BEGIN UPDATE writeCounter SET seq = seq + 1; UPDATE deliveryRequests SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid; END;
CREATE TRIGGER deliveryRequests_writeSeq_update AFTER UPDATE OF status ON deliveryRequests WHEN old.status IS NOT new.status BEGIN UPDATE writeCounter SET seq = seq + 1; UPDATE deliveryRequests SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid; END;
CREATE TABLE macPresence (id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, onlineUntil INTEGER NOT NULL, modifiedAt INTEGER NOT NULL) STRICT;
CREATE TABLE macAgents (id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, agents TEXT, problems TEXT, modifiedAt INTEGER NOT NULL, name TEXT) STRICT;
CREATE TABLE agentLibraries (
  id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, home TEXT NOT NULL, skills TEXT, instructions TEXT, tidies TEXT, selfManaged TEXT,
  agents TEXT, modifiedAt INTEGER NOT NULL
) STRICT;
CREATE TABLE agentLibraryFiles (
  id TEXT PRIMARY KEY NOT NULL, hostID TEXT NOT NULL, path TEXT NOT NULL, hash TEXT NOT NULL, text TEXT NOT NULL, modifiedAt INTEGER NOT NULL
) STRICT;
CREATE INDEX agentLibraryFiles_host ON agentLibraryFiles(hostID);
CREATE TABLE sessionViewers (
  id TEXT PRIMARY KEY NOT NULL, device TEXT NOT NULL, sessionID TEXT, modifiedAt INTEGER NOT NULL, cue INTEGER, arrivedAt INTEGER
) STRICT;
CREATE VIRTUAL TABLE searchIndex USING fts5(text, refID, kind UNINDEXED, tokenize = 'trigram');
CREATE TRIGGER searchIndex_projects_insert AFTER INSERT ON projects BEGIN INSERT INTO searchIndex(text, refID, kind)
SELECT new.name, new.id, 'project' WHERE new.name <> ''; END;
CREATE TRIGGER searchIndex_projects_update AFTER UPDATE OF name ON projects BEGIN DELETE FROM searchIndex WHERE searchIndex MATCH 'refID: "' || old.id || '"'; INSERT INTO searchIndex(text, refID, kind)
SELECT new.name, new.id, 'project' WHERE new.name <> ''; END;
CREATE TRIGGER searchIndex_projects_delete AFTER DELETE ON projects BEGIN DELETE FROM searchIndex WHERE searchIndex MATCH 'refID: "' || old.id || '"'; END;
CREATE TRIGGER searchIndex_cards_insert AFTER INSERT ON cards BEGIN INSERT INTO searchIndex(text, refID, kind)
SELECT new.body, new.id, 'card' WHERE new.body <> ''; END;
CREATE TRIGGER searchIndex_cards_update AFTER UPDATE OF body ON cards BEGIN DELETE FROM searchIndex WHERE searchIndex MATCH 'refID: "' || old.id || '"'; INSERT INTO searchIndex(text, refID, kind)
SELECT new.body, new.id, 'card' WHERE new.body <> ''; END;
CREATE TRIGGER searchIndex_cards_delete AFTER DELETE ON cards BEGIN DELETE FROM searchIndex WHERE searchIndex MATCH 'refID: "' || old.id || '"'; END;
CREATE INDEX syncRecords_recordType ON syncRecords(recordType, pushedModifiedAt, recordName);
CREATE INDEX syncRecords_pushed ON syncRecords(recordName, pushedModifiedAt);
CREATE INDEX projects_modified ON projects(id, modifiedAt);
CREATE INDEX cards_modified ON cards(id, modifiedAt);
CREATE INDEX sendRecords_modified ON sendRecords(id, modifiedAt);
CREATE INDEX attachments_modified ON attachments(id, modifiedAt);
CREATE INDEX piSessionStates_modified ON piSessionStates(id, modifiedAt);
CREATE INDEX agentCatalogs_modified ON agentCatalogs(id, modifiedAt);
CREATE INDEX deliveryRequests_modified ON deliveryRequests(id, modifiedAt);
CREATE INDEX directoryBindings_modified ON directoryBindings(id, modifiedAt);
CREATE INDEX piMessages_modified ON piMessages(id, modifiedAt);
CREATE INDEX previews_modified ON previews(id, modifiedAt);
CREATE INDEX accountQuotas_modified ON accountQuotas(id, modifiedAt);
CREATE INDEX cueMessages_modified ON cueMessages(id, modifiedAt);
CREATE INDEX cueLines_modified ON cueLines(id, modifiedAt);
CREATE INDEX cueProfile_modified ON cueProfile(id, modifiedAt);
CREATE INDEX cueState_modified ON cueState(id, modifiedAt);
CREATE INDEX cueRead_modified ON cueRead(id, modifiedAt);
CREATE INDEX macPresence_modified ON macPresence(id, modifiedAt);
CREATE INDEX macAgents_modified ON macAgents(id, modifiedAt);
CREATE INDEX sessionViewers_modified ON sessionViewers(id, modifiedAt);
CREATE INDEX agentLibraries_modified ON agentLibraries(id, modifiedAt);
CREATE INDEX agentLibraryFiles_modified ON agentLibraryFiles(id, modifiedAt);
INSERT INTO projects (id, name, icon, color, isPinned, deletedAt, createdAt, modifiedAt, intro) VALUES ('d221f17f-a411-58f4-ade3-86795722b868', '默认', 'house', '#8A8A84', 0, NULL, 0, 0, NULL);
INSERT INTO writeCounter (seq) VALUES (0);
PRAGMA user_version = 77;
"""#
}
