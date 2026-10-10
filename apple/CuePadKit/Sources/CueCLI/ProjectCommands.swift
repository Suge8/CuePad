import CueStore

extension Command {
  static let project: [Command] = [
    Command(
      path: ["project", "list"], summary: "列出项目（置顶在前，其余按最近活动）",
      notes: Schema.output("[Project]", Schema.project) + "\n未分类的灵感用 cuepad card list --inbox 查看。"
    ) { call in
      try call.args.expect()
      let views = try await call.projectViews(try await call.store.projects())
      return listReply(views.map(\.line), json: views.map(\.json))
    }
  ]
}
