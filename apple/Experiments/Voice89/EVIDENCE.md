# #89 取证归档

这份目录不属于 App 的 Sources 同步组，不编入产品，没有启动钩子。`Sources` 保留生命周期修复后的临时探针；它不是正式 Relay/媒体实现，也不是新增的项目单元或集成测试。

## 证据更正

2026-11-08 的旧探针（提交 `f532b78fa`）真实完成了 iOS 模拟器媒体与独立 Mac 进程的授权创建、应答和控制；合成输入两轮分别收到 743、765 个音频包，并录得非零音频。原日志保留在 `Evidence/voice89-*-audio.log`，音频摘要在 `Evidence/audio-manifest.json`；原 WAV/PCM 本地归档在 `apple/.derived/voice89-evidence`，没有提交大型二进制。

这些证据只代表两轮正常路径：

- 旧标签帧被过滤，不证明旧 WebKit 回调不会污染新媒体。审计真实页面脚本与替身复现了 `old track callback attached to context 2`，见 `Evidence/voice89-lifecycle-before.log`。
- 旧 100 秒期限、异常退出以及 Mac 控制回调有代码路径风险；审计没有实测资源泄漏，不能据此声称发生泄漏，也不能沿用“可靠关闭所有路径”的结论。
- 旧正常挂断日志只证明当时观测到的本地资源状态；没有服务器计费结束或回收确认。
- 本次没有重跑付费真实调用、没有读取授权。真机听说、真实跨设备、后台/锁屏/蓝牙与真实业务身份闭环仍未覆盖。

## 修复验证

每轮独立持有网页、音频上下文、轨道、操作 continuation 与任务；Native 和 JS 的取消都只影响原 owner。正常/异常共同执行显式 shut，清理超时只能报告未确认。Mac 创建任务不占用输入事件循环，旧控制错误只能关闭旧 owner。

| 临时复现 | 本次结果 | 证据 |
|---|---|---|
| 保存旧 ontrack，在新轮启动后调用 | 不连接任何新上下文，迟到旧轨道被停止 | lifecycle-after.log |
| 正常关闭及 offer 异常后的显式清理 | 输入/输出轨道 ended、peer/context closed | lifecycle-after.log |
| 采集授权与 WebAudio Promise 挂起时关闭 | 等待立即拒绝；晚返回采集轨道被停止 | lifecycle-after.log |
| 原生权限/JS/send continuation 挂起后取消 | 不等回调即结束；迟到回调不二次恢复 | lifecycle-native-final.log |
| 创建 call 挂起期间挂断 | 立即收尾，释放创建返回后不发送迟到 answer | lifecycle-native-final.log |
| 旧 sideband send 挂起，关旧轮/开新轮后才失败 | 新轮控制未被关闭 | lifecycle-native-final.log |

原生复现由 `xc.sh run mac -- -CuePadSplitVoice audit` 在探针撤出前执行，用受控替身挂起回调；修复版也完成了 iOS 编译及 `xc.sh check`。它验证取消和所有权逻辑，不冒充真实 OS 权限窗口/进程失响应实测。100 秒期限调用同一取消入口，本次直接触发该入口，没有等待 100 秒。归档源码是编译/执行过的那份，随后撤掉 App 启动钩子。

重跑不收费的页面与互操作复现（从仓库根目录）：

```sh
node apple/Experiments/Voice89/lifecycle.cjs apple/Experiments/Voice89/Sources/DebugSplitMedia+Page.swift
node apple/Experiments/Voice89/wire.cjs apple/Experiments/Voice89/Evidence/voice89-wire-fixture.json
```

两条命令均应只打印 PASS。复现原始缺陷：

```sh
git show f532b78fa:apple/App/Sources/UI/Debug/DebugSplitMedia+Page.swift > /tmp/voice89-original-page.swift
node apple/Experiments/Voice89/before.cjs /tmp/voice89-original-page.swift
```

应打印 `old track callback attached to context 2`。原生修复复现是归档的 `DebugSplitAudit.swift`，不作为默认测试或产品入口继续保留。

## 互操作样例的范围

`Evidence/voice89-wire-fixture.json` 是实际 Swift Codable/CryptoKit 生成的帧；固定样例 secret 已公开，`testOnly=true`，时间也固定，禁止用于真实通话。它包含 ready、register/registered、resolve/resolved/unavailable、signal、departed(disconnected/replaced)、rejected。

`wire.cjs` 用 Node 标准库验证登记签名与规范编码，打开 AES-GCM 样例并确认篡改拒绝。它没有验证正式服务器成员/租约/重放/断连逻辑。那些正式实现尚不存在，不宣称 checkpoint 已完成安全接入。

正式可编译值类型及边界在 `App/Sources/Services/VoiceSessionTypes.swift`、`VoiceCommandTypes.swift`、`VoiceMediaSession.swift`、`VoiceSignalTypes.swift`、`VoiceSignaling.swift`；没有给现有 Relay 添加空实现或成功返回。任何正常项目测试都未删除或弱化。
