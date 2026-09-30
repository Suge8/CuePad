import CueStore
import Foundation

extension Command {
  static let card: [Command] = [
    Command(
      path: ["card", "list"], summary: "列出卡片（默认所有项目，项目内按手动顺序）",
      options: [
        .project("只列该项目"), .inbox, Opt("favorites", "只列收藏"), Opt("trash", "列回收站里单独删除的卡片"),
      ],
      notes: "输出：[Card]（含完整正文）。"
    ) { call in
      try call.args.expect()
      let scope = try await call.scope()
      let cards = try await listedCards(call).filter {
        scope.contains($0.projectID) && (!call.args.has("favorites") || $0.isFavorite)
      }
      let views = try await call.cardViews(cards)
      return listReply(views.map(\.line), json: views.map(\.json))
    },
    Command(
      path: ["card", "show"], summary: "显示一张卡片", arguments: "<卡片>",
      options: [Opt("body", "只输出正文，原样（供管道使用）")],
      notes: "输出：Card。--body 与 --json 同用时仍输出 JSON。"
    ) { call in
      try call.args.expect("卡片")
      let card = try await call.card(call.args.positionals[0])
      let view = try await call.cardViews([card])[0]
      return Reply(text: call.args.has("body") ? card.body : view.detail + "\n", json: view.json)
    },
    Command(
      path: ["card", "add"], summary: "新建卡片（放在项目最前）",
      options: [.project("放进该项目；省略则进未归档"), .inbox, .body],
      notes: "输出：新建的 Card。例：printf '第一段\\n---split---\\n第二段' | cuepad card add --project CuePad"
    ) { call in
      try call.args.expect()
      let scope = try await call.scope()
      let body = try call.bodyInput()
      let card = try await call.store.createCard(in: scope.target, body: body)
      return reply(try await call.cardViews([card])[0])
    },
    Command(
      path: ["card", "edit"], summary: "替换卡片正文", arguments: "<卡片>",
      options: [.body], notes: "输出：更新后的 Card。"
    ) { call in
      try call.args.expect("卡片")
      let card = try await call.card(call.args.positionals[0])
      let body = try call.bodyInput()
      try await call.store.updateCard(card.id) { $0.body = body }
      return reply(try await fresh(call, card.id))
    },
    Command(
      path: ["card", "move"], summary: "把卡片移到另一个项目或未归档", arguments: "<卡片>",
      options: [
        .project("目标项目"), .inbox, Opt("after", "放在这张卡片之后（须在目标项目里）；省略则放最前", value: "卡片"),
      ],
      notes: "--project 与 --inbox 必须给一个。输出：移动后的 Card。"
    ) { call in
      try call.args.expect("卡片")
      let scope = try await call.scope()
      if case .any = scope { throw CLIError.usage("需要 --project <项目> 或 --inbox") }
      let card = try await call.card(call.args.positionals[0])
      let previous = try await call.args.value("after").asyncMap { try await call.card($0).id }
      try await call.store.moveCard(card.id, to: scope.target, after: previous)
      return reply(try await fresh(call, card.id))
    },
    Command(
      path: ["card", "trash"], summary: "移进回收站", arguments: "<卡片>", notes: "输出：Card（deletedAt 有值）。"
    ) { call in
      try call.args.expect("卡片")
      let card = try await call.card(call.args.positionals[0])
      try await call.store.trashCard(card.id)
      return reply(try await fresh(call, card.id))
    },
    Command(
      path: ["card", "restore"], summary: "从回收站恢复（原项目仍在回收站时回到未归档）", arguments: "<卡片>",
      notes: "输出：恢复后的 Card。"
    ) { call in
      try call.args.expect("卡片")
      let card = try await call.card(call.args.positionals[0])
      try await call.store.restoreCard(card.id)
      return reply(try await fresh(call, card.id))
    },
  ]

  private static func listedCards(_ call: Call) async throws -> [Card] {
    if call.args.has("trash") { return try await call.store.trashedCards() }
    var cards: [Card] = []
    for project in try await call.store.projects() { cards += try await call.store.cards(in: project.id) }
    return cards + (try await call.store.cards(in: nil))
  }

  private static func fresh(_ call: Call, _ id: UUID) async throws -> CardView {
    guard let card = try await call.store.card(id) else { throw CLIError.notFound("卡片 \(id.uuidString.lowercased()) 已不存在") }
    return try await call.cardViews([card])[0]
  }
}
