import CueStore
import Testing

@testable import CueSync

/// CKSyncEngine 只弱引用它的委托。委托若没有别人强持有，引擎的事件（状态保存、账号变化、拉取与发送结果）
/// 全被丢掉——真机上引擎在跑，库里却没有一条同步记录。委托必须与 CloudSync 同生命周期。
@Suite struct EngineDelegateTests {
  @Test func cloudSyncKeepsItsEngineDelegateAlive() throws {
    let fixture = try Fixture()
    var sync: CloudSync? = CloudSync(store: fixture.store, subscribesToAlerts: false)
    weak let delegate = sync?.engineDelegate
    #expect(delegate != nil, "外部没有任何引用时，委托仍由 CloudSync 持有")
    sync = nil
    #expect(delegate == nil, "CloudSync 释放后委托随之释放，不是被别处泄漏持有")
  }
}
