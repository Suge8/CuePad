import CueStore
import CueTestSupport
import Foundation
import Testing

/// 任务只是一件要做成的事（标题与可选一句说明），要发给 Agent 的话是挂在它下面的灵感——任务里叫"提示词"。
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
}
