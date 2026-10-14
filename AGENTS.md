# CuePad

Swift 原生应用（macOS / iOS / iPadOS），产品见 [README.md](README.md)。叫法见 [WORDS.md](WORDS.md)；业务规则在所属类型的头注释里。

## 命令

- 构建、测试、截图、发布只经 `apple/scripts/xc.sh`（用法见头注释）；共用包 `cd apple/CuePadKit && swift test`；`cuepad --help` 是命令行唯一文档。测试摘要里的 "Executed N tests" 只数 XCTest，Swift Testing 的用例不在内。
- 提交前跑 `apple/scripts/xc.sh check`：源码约束检查（`lint.sh`）加 Kit 与 iOS 编译。
- 报"没有这个成员"而代码里明明有，或改了 CuePadKit 公开类型的存储属性后 App 一启动就崩在 Kit 的释放里：旧的模块缓存，依赖它的模块还按旧内存布局读。删 `<产物目录>/Build/Products/<平台>/Cue*.swiftmodule` 再编，仍不行就换空产物目录整编。

## 护栏

- 并行工作在自己的检出里做：在主检出里 `git worktree add ../CuePad-wt/<名> -b feat/<名>`，并设 `CUEPAD_DERIVED=/tmp/<名>`（同一产物目录的构建与测试会互相覆盖）。主检出只读：那里常有别人没提交的改动。
- 发布只在干净检出运行 `xc.sh release`，对外发布只在用户明确要求时做（见 docs/release.md）。
- 结束或操作 CuePad 只按自己启动的进程 PID：`killall`、`pkill -f`、按应用名 quit 会关掉用户正在用的正式版。
- 本机构建只开隔离库（`CUEPAD_LIBRARY_DIR`，库、偏好都在里面）；要接入 Agent 时再同时给 `PI_CODING_AGENT_DIR`、`CUEPAD_BIN_DIR` 与 `CUEPAD_PI_SOCKET_DIR`（其余几家另给 `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`OPENCODE_CONFIG_DIR`）（不给连接目录，桥会连上用户正在跑的会话）。不读写真实资料库（位置见 `LibraryLocation`）、偏好域 `com.sugeh.cuepad`、`~/.pi` 与 `~/.local/bin`：本机构建一打开真实库就会升级结构、改写数据并同步出去，正式版之后就打不开了。看真实数据只用只读副本（docs/verify.md「真实数据复现」）。
- 测试只用替身，不向其他应用发键鼠事件；全局热键的物理触发与跨应用粘贴只能人工验证。
- 用户可见行为的端到端测试从 `Workspace` 的方法走（界面的按钮、菜单调的就是它），断言库、提示与回复框，放在 `App/Tests/UI` 的流程测试里；接线与长相用交互验收（docs/verify.md）。
- 跨会话、暂不做的待办在 GitHub Issues（`gh issue list`）；谁在做什么看 `git worktree list` 的分支名。

## 碰到这些先读

- 界面配色、动效、布局、渲染性能 → [docs/ui.md](docs/ui.md)
- 同步、投送请求、CloudKit 订阅、同步排查 → [docs/sync.md](docs/sync.md)
- 截图验收、交互验收、性能测量、崩溃诊断 → [docs/verify.md](docs/verify.md)
- 签名、发布、Sparkle、CloudKit 结构部署 → [docs/release.md](docs/release.md)
- Agent 桥、socket 协议、各家接入 → [CuePi README](apple/CuePadKit/Sources/CuePi/README.md)
- 落地页 → [landing/AGENTS.md](landing/AGENTS.md)
