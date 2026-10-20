# CuePad

Swift 原生应用（macOS / iOS / iPadOS），产品见 [README.md](README.md)。叫法见 [WORDS.md](WORDS.md)；业务规则在所属类型的头注释里。

## 命令

- 构建、测试、截图、录屏、测量、发布只经 `apple/scripts/xc.sh`（用法见头注释），共用包是 `xc.sh test kit`，提交前跑 `xc.sh check`。绕开它的构建命令和按名字或 bundle id 起停 CuePad（与正式版同一个 bundle id）会被 Pi 扩展拦下。
- 提交钩子拦下超过 5000 令牌（字节数 ÷ 4，约 20KB）的新文件与变大的超标文件，拆法在它的报错里：新代码按职责分文件写，不往超标文件里加。
- 调试实例只用 `xc.sh shot|rec|run` 起（隔离、用完自己退出，`run` 起的用 `xc.sh stop` 收），别的进程只按自己拿到的 PID 结束。排队等过上限以 75 退出并列出持有者（`_lock.sh` 头注释）。
- 测试摘要里的 "Executed N tests" 只数 XCTest，Swift Testing 的用例不在内。
- `cuepad --help` 是命令行唯一文档。
- 报"没有这个成员"而代码里明明有，或改了 CuePadKit 公开类型的存储属性后 App 一启动就崩在 Kit 的释放里：检出里还留着旧版 xc.sh 只编 App 时的静态模块（原因见 xc.sh 的 `xcd`），删一次 `apple/.derived/Build/Products/<平台>/Cue*.swiftmodule` 再编。

## 护栏

- 并行工作在自己的检出里做：在主检出里 `git worktree add ../CuePad-wt/<名> -b feat/<名>`。主检出只读：那里常有别人没提交的改动。
- 发布只在干净检出运行 `xc.sh release`，对外发布只在用户明确要求时做（见 docs/release.md）。
- 本机构建只开隔离库（隔离哪些目录只在 `app.py` 的 `isolated_env`）；终端里起的会话要连上 `xc.sh` 起的实例就 `export CUEPAD_PI_SOCKET_DIR=$(python3 apple/scripts/app.py sockets)`。不读写真实资料库（位置见 `LibraryLocation`）、偏好域 `com.sugeh.cuepad`、`~/.pi` 与 `~/.local/bin`：本机构建一打开真实库就会升级结构、改写数据并同步出去，正式版之后就打不开了。看真实数据只用只读副本（docs/verify.md「真实数据复现」）。
- 测试只用替身，不向其他应用发键鼠事件；全局热键的物理触发与跨应用粘贴只能人工验证。
- 用户可见行为的端到端测试从 `Workspace` 的方法走（界面的按钮、菜单调的就是它），断言库、提示与回复框，放在 `App/Tests/UI` 的流程测试里；接线与长相用交互验收（docs/verify.md）。
- 跨会话、暂不做的待办在 GitHub Issues（`gh issue list`）；谁在做什么看 `git worktree list` 的分支名。

## 碰到这些先读

- 界面配色、动效、布局、渲染性能 → [docs/ui.md](docs/ui.md)
- 同步、投送请求、CloudKit 订阅、通知、同步排查 → [docs/sync.md](docs/sync.md)
- 截图验收、交互验收、通知验收、性能测量、崩溃诊断、改 Cue 提示词的前后评测、要占前台（截系统菜单、在前台量帧） → [docs/verify.md](docs/verify.md)
- 签名、发布、Sparkle、CloudKit 结构部署 → [docs/release.md](docs/release.md)
- Agent 桥、socket 协议、各家接入 → [CuePi README](apple/CuePadKit/Sources/CuePi/README.md)
- 落地页 → [landing/AGENTS.md](landing/AGENTS.md)
