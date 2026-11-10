# 通话验收

改 Cue 通话（接通、音频、信令、交接、朗读）后照这里验；通用的起实例与读界面办法在 [verify.md](verify.md)「交互验收」。

- 和 Cue 通话（Mac）：`run` 起的实例没有菜单栏，用 `-CuePadVoice mic`（麦克风，人工）或 `-CuePadVoice <音频文件|目录>` 调菜单那一项的同一个动作；令牌先 `scripts/voice-token.py <文件>` 经本机 Codex app-server 获取，经 `-CuePadVoiceToken <文件>` 交给实例，Cue 用真 Claude Code（[verify.md](verify.md)「交互验收」里"让 Cue 真跑"那条） 或 `-CuePadCueBrain` 替身（参数见 `DebugScene+Voice.swift` 头注释）。手机发起的：模拟器实例带 `-CuePadVoice <音频文件>`，Mac 实例带令牌、不带 `-CuePadVoice`，两端同一朵模拟云（`DebugScene+PhoneVoiceCall.swift` 头注释）。
- 文件声源（`VoiceFixture`）直接送进 WebRTC 的上行，不碰麦克风、不建设备、不外放，也不经语音处理（麦克风经系统的那一套）：Cue 在停顿处抢话的多少只在真机上作数。`-CuePadVoiceRecord <wav>` 录下对方的声音，内容用本机转写核对。手机进后台、被收走声音（中断）、信令断开也能在模拟器上验：
  1. Mac：`xc.sh run mac -- -CuePadCueBrain apple/scripts/cue-brain-stub.py -CuePadVoiceToken <令牌> -CuePadSharedCloud <目录> -CuePadVoiceLog <mac.log>`。
  2. 手机：`xc.sh run ios -- -CuePadSharedCloud <同一目录> -CuePadVoice <wav> -CuePadVoiceLog <ios.log> -CuePadVoiceSeconds 40`，后台加 `-CuePadVoicePlayInBackground YES`，中断加 `-CuePadVoiceInterruptAfter 6`，信令断开加 `-CuePadVoiceDropRelay <在听后秒>,<断多久秒>`（两端都认；Mac 端 `-CuePadVoiceFailProjection <在听后秒>,<多久秒>` 让投影发送失败；Mac 端给 `-CuePadVoiceSeconds` 就在接通后这么久挂断，验 Mac 先结束）。
  3. 后台：ios.log 出现 `waiting-background` 后 `xcrun simctl launch <UDID> com.apple.Preferences`。应看到 `app-background` 之后才 `play`，Mac 日志有这句的 `user-said` 与委派，最后 `ended(… hungUp)`。
  4. 信令断开：断得比 15 秒短的，ios.log 依次 `relay-drop`、`link relinking(…)`、`link bound(…)`，通话照常、`projection` 补到最新；更长的在断开后约 15 秒 `ended(… networkFailed)`。Mac 日志对应 `relinking`、`relinked`。投影发送失败的：Mac 只有 `projection-fail`、没有 `relinking`，窗口过后手机 `projection` 接着更新。手机加 `-CuePadVoiceRepeatOnReturn YES` 在中转连回时请重说：Mac 记 `relinked by command(…)`，手机 `repeat-result` 后 `projection` 照常更新。
  5. 中断：ios.log `interrupt` 后紧跟 `ended(… audioInterrupted)`，Mac 日志 `failed(media(audioInterrupted))`，手机提示条"音频已中断"。系统的语音处理（回声消除、降噪、增益）、蓝牙与听筒、真的来电或 Siri、锁屏，只能在真机上人工验。
- GPT Live 先筛选、整理，再以 delegation 交接给 Cue；`turn.done` 只是转写。核对交接正文、卡片、用户消息送达与最终回复的 `answeredRequests`；`-CuePadVoiceReplay YES` 在回复后重放交接与转写，库里应仍只有原请求。问候与普通闲聊不应写成 Cue 请求。
- 朗读验收分开核对 `cue-forward`（Cue 实际结果和交接 ID）、`cue-sent`（发送完成）、`context-accepted`（服务器追加回执）、`assistant-said`（模型转写），最后对照 `output-loud/quiet` 与真实输出录音。只有音轨证据能证明出声，内容仍须回放核实；回执不能当作必播或播完。v3 的 `speakable` 是播报输入，关闭 `ack_filler` 也不保证模型不会自行确认或漏交接。停止请求必须实际交接、由 Cue 确认后再查录音；不能因听到模型说停下就算任务已停止。
