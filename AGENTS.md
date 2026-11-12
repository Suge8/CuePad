# CuePad

Swift 原生应用（macOS / iOS / iPadOS）。术语见 [WORDS.md](WORDS.md)。

注释默认不写，除非必要，只写三种：调用方从声明看不出、用错会出事的入口约定（边界、不变量、失败、线程）；代码看不出的原因（外部的怪行为、竞态、实测数字、否决的方案），写在相关代码旁；跨处的规则在不好找的地方指向它的归属。不复述实现，类型名已说清的不写头注释。业务规则以实现为准，用户看得见的由端到端测试守住；改行为时在同一改动里改相关说明。

## 命令

- 构建、测试、截图、录屏、测量、发布只经 `apple/scripts/xc.sh`（用法见头注释），共用包是 `xc.sh test kit`，提交前跑 `xc.sh check`。它在前台跑到结束（排队、时限都在里面），不放后台再 sleep 轮询。
- 新代码按职责分文件写：提交钩子拦下超过约 20KB 的新文件与变大的超标文件。
- 调试实例只用 `xc.sh shot|rec|run` 起（隔离、用完自己退出，`run` 起的用 `xc.sh stop` 收）；多张图在一次调用里拍（用 `,` 隔开，见 xc.sh 头注释），不一张一次、不另写批拍脚本。CuePad 与正式版同一个 bundle id：进程只按自己拿到的 PID 结束，不按名字。
- `xc.sh test` 收尾有一页结论：先看它，别翻日志。
- 合并前的门是本机的 `xc.sh signoff`：推送后在干净的检出里跑，全过才给这个提交记上 GitHub 状态 `signoff`，主干的规则见到它才让 PR 合并（`gh pr merge` 不带 `--admin`）；改了再推就重签。PR 不在云端跑。
- 云端 CI（`.github/workflows/swift.yml`）只在合并进主干后跑全量兜底（真 Agent 全量、iOS 同步）。合并后不用守着它；合并前先看主干最近一遍（`gh run list --branch main`）：红的先处理，改动造成的修或回退那次合并，runner 自己崩的重跑。发布只认它全绿的提交。lint 要完整的 Git 检出（origin/main、发布标签），`git archive` 导出的副本跑不了。
- `cuepad --help` 是命令行唯一文档。
- 报"没有这个成员"而代码里明明有，或改了 CuePadKit 公开类型的存储属性后 App 一启动就崩在 Kit 的释放里：检出里还留着旧版 xc.sh 只编 App 时的静态模块（原因见 xc.sh 的 `xcd`），删一次 `apple/.derived/Build/Products/<平台>/Cue*.swiftmodule` 与 `apple/.derived-wmo/Build/Products/<平台>/Cue*.swiftmodule`（`check` 在后者里编）再编。

## 护栏

- 并行工作在自己的检出里做：在主检出里 `git worktree add ../CuePad-wt/<名> -b feat/<名>`。主检出只读：那里常有别人没提交的改动。
- 冻结：两份 README 与落地页（`landing/`）现在是占位，`design/readme/` 的截图不重拍；等用户说大更新落地再重写，期间只改 lint 要求与 `Palette` 同步的 `landing/src/styles/base.css` 令牌。
- 发布只在干净检出运行 `xc.sh release`，对外发布只在用户明确要求时做（见 docs/release.md）。
- 本机构建只开隔离库（隔离哪些目录只在 `app_env.py` 的 `isolated_env`）；手动起一个连上 `xc.sh` 起的实例的 Pi 会话见 CueBridge README「调试」。不读写真实资料库（位置见 `LibraryLocation`）、偏好域（App 身份前缀，`Signing.xcconfig` 的 `CUEPAD_APP_ID`）、`~/.pi` 与 `~/.local/bin`：本机构建一打开真实库就会升级结构、改写数据并同步出去，正式版之后就打不开了。看真实数据只用只读副本（docs/verify.md「真实数据复现」）。
- 测试只用替身，不向其他应用发键鼠事件；全局热键的物理触发与跨应用粘贴只能人工验证。
- 用户可见行为的端到端测试从 `Workspace` 的方法走（界面的按钮、菜单调的就是它），断言库、提示与回复框，放在 `App/Tests/UI` 的流程测试里；接线与长相用交互验收（docs/verify.md）。
- 跨会话、暂不做的待办在 GitHub Issues（`gh issue list`）；谁在做什么看 `git worktree list` 的分支名。

## 碰到这些先读

- 界面：配色、选中与悬停、栏头与页顶、浮层、开合、布局稳定、渲染性能 → [docs/ui.md](docs/ui.md)
- 加、改界面上的字，英文版 → [docs/i18n.md](docs/i18n.md)
- 同步、投送请求、CloudKit 订阅、通知、同步排查 → [docs/sync.md](docs/sync.md)
- 截图验收、交互验收、通知验收、要占前台（截系统菜单、在前台量帧） → [docs/verify.md](docs/verify.md)
- 改 Cue 通话后的验收（后台、中断、信令断开、交接、朗读）→ [docs/verify-voice.md](docs/verify-voice.md)
- 真机上的崩溃、卡住、取日志 → [docs/diagnose.md](docs/diagnose.md)
- 性能测量、交互预算、同步测量 → [docs/perf.md](docs/perf.md)
- 要量一处改动对 Cue 做法的影响（评测、记忆基准）→ [docs/cue-eval.md](docs/cue-eval.md)
- 签名、发布、Sparkle、CloudKit 结构部署 → [docs/release.md](docs/release.md)
- Pi 桥扩展的协议约定与边界 → [CueBridge README](apple/CuePadKit/Sources/CueBridge/README.md)
