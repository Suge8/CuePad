import CueStore
import CueTestSupport
import Foundation
import Testing

/// 任务只是一件要做成的事（正文只有标题），要发给 Agent 的话是挂在它下面的灵感——任务里叫"提示词"。
@Suite struct PromptTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  // MARK: 设为任务

  @Test func 多行的灵感设为任务_第一行是任务_其余成为它的提示词() async throws {
    let idea = try await store.createCard(in: nil, body: "上线前检查\n把 changelog 过一遍\n看下崩溃率")
    try await store.setTodo(idea.id, true)
    #expect(try await store.card(idea.id)?.body == "上线前检查")
    #expect(try await store.children(of: idea.id).map(\.body) == ["把 changelog 过一遍\n看下崩溃率"])

    let single = try await store.createCard(in: nil, body: "续费域名")
    try await store.setTodo(single.id, true)
    #expect(try await store.children(of: single.id).isEmpty)
  }

  @Test func 步骤是叶子_多出来的话是它自己的草稿_再多出来的并进同一条() async throws {
    let top = try await store.createTask("修乱序", in: nil)
    let step = try await store.createTask("复现\n先看日志", under: top.id)
    #expect(try await store.card(step.id)?.body == "复现")
    #expect(try await store.children(of: top.id).map(\.id) == [step.id])
    let draft = try #require(try await store.children(of: step.id).first)
    #expect(draft.body == "先看日志")

    try await store.updateCard(step.id) { $0.body = "复现\n再来一遍" }
    let children = try await store.children(of: step.id)
    #expect(children.map(\.id) == [draft.id] && children[0].body == "先看日志\n\n再来一遍")
  }
}
