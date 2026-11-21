import Foundation

extension CueStore {
  public func recordAgentLibrary(_ library: AgentLibrary, texts: [String: String]) throws {
    try write {
      let host = library.hostID
      if try find(AgentLibrary.self, AgentLibrary.recordID(host: host))?.sameContent(as: library) != true {
        var record = library
        record.modifiedAt = Date.stamp
        try upsert(record)
      }
      let stored = Dictionary(
        uniqueKeysWithValues: try db.query("SELECT path, hash FROM agentLibraryFiles WHERE hostID = ?", [host]) { ($0.text(0), $0.text(1)) })
      for (path, text) in texts where stored[path] != LibraryEdit.base(of: text) {
        try upsert(LibraryFileText(hostID: host, path: path, text: text, modifiedAt: Date.stamp))
      }
      for path in stored.keys where texts[path] == nil {
        try db.run("DELETE FROM agentLibraryFiles WHERE id = ?", [LibraryFileText.recordID(host: host, path: path)])
      }
    }
  }

  public func agentLibrary(host: String?) throws -> AgentLibrary? {
    if let host { return try find(AgentLibrary.self, AgentLibrary.recordID(host: host)) }
    if let cue = try cueProfile()?.hostID, let library = try find(AgentLibrary.self, AgentLibrary.recordID(host: cue)) { return library }
    return try select(AgentLibrary.self, orderBy: "modifiedAt DESC").first
  }

  public func agentLibraryTexts(host: String, paths: [String]) throws -> [String: String] {
    let ids = JSONColumn.encode(paths.map { LibraryFileText.recordID(host: host, path: $0).uuidString.lowercased() })
    let rows = try select(LibraryFileText.self, where: "id IN (SELECT value FROM json_each(?))", [ids])
    return Dictionary(rows.map { ($0.path, $0.text) }, uniquingKeysWith: { a, _ in a })
  }
}
