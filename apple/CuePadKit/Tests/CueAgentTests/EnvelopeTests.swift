import CueAgent
import CueStore
import Foundation
import Testing

/// 交给 Cue 的大脑的信封。
@Suite struct EnvelopeTests {
  /// 刚启用的第一次醒来，信封里写明原因。
  @Test func theFirstWakeAfterEnablingSaysSo() {
    let text = CueEnvelope.render(.init(
      now: .now, contextUsed: nil, renewAt: 150_000, since: .now, projects: [], changes: [], board: [], waiting: [], wake: .enabled, said: nil))
    #expect(text.split(separator: "\n").contains("醒来：刚启用"))
  }

  /// 每次醒来都看得到有哪些项目（只有一个也列），没绑文件夹的标出来：Cue 据此把活放进项目。
  @Test func everyWakeListsTheProjectsAndWhichHaveNoFolder() {
    let projects = [CueProject(id: UUID(), name: "greet", hasFolder: true), CueProject(id: UUID(), name: "随记", hasFolder: false)]
    let text = CueEnvelope.render(.init(
      now: .now, contextUsed: nil, renewAt: 150_000, since: .now, projects: projects, changes: [], board: [], waiting: [], wake: .idle, said: nil))
    #expect(text.split(separator: "\n").contains("项目：greet、随记（没绑文件夹）"))
    let single = CueEnvelope.render(.init(
      now: .now, contextUsed: nil, renewAt: 150_000, since: .now, projects: [projects[0]], changes: [], board: [], waiting: [], wake: .idle, said: nil))
    #expect(single.split(separator: "\n").contains("项目：greet"))
  }
}
