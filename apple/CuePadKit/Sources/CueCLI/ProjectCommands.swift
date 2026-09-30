import CueStore

extension Command {
  static let project: [Command] = [
    Command(
      path: ["project", "list"], summary: "列出项目（手动顺序）",
      notes: Schema.output("[Project]", Schema.project) + "\n未归档的卡片用 cuepad card list --inbox 查看。"
    ) { call in
      try call.args.expect()
      let counts = Dictionary(
        uniqueKeysWithValues: try await call.store.projectSummaries().map { ($0.projectID, $0.cardCount) })
      let directories = try await call.store.projectDirectories()
      let views = try await call.store.projects().map {
        ProjectView(project: $0, cardCount: counts[$0.id] ?? 0, directory: directories[$0.id])
      }
      return listReply(views.map(\.line), json: views.map(\.json))
    }
  ]
}
