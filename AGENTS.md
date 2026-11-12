# CuePad

Swift 原生应用（macOS / iOS / iPadOS）。术语见 [WORDS.md](WORDS.md)。

注释默认不写，除非必要，只写三种：调用方从声明看不出、用错会出事的入口约定（边界、不变量、失败、线程）；代码看不出的原因（外部的怪行为、竞态、实测数字、否决的方案），写在相关代码旁；跨处的规则在不好找的地方指向它的归属。不复述实现，类型名已说清的不写头注释。业务规则以实现为准，用户看得见的由端到端测试守住；改了行为，旁边的注释与报错跟着改。

## 命令

- 构建、测试、截图、录屏、测量、发布只经 `apple/scripts/xc.sh`（`xc.sh help` 列出全部命令），提交前跑 `xc.sh check`。它在前台跑到结束，排队与时限都在里面。
- 调试实例用 `xc.sh shot|rec|run` 起，`run` 起的用 `xc.sh stop` 收；多张图在一次调用里拍（用 `,` 隔开）。
- 合并前的门是本机的 `xc.sh signoff`：推送后跑，过了主干的规则才让 PR 合并（`gh pr merge` 不带 `--admin`）；改了再推就重签。合并后在主检出跑一次 `git pull --ff-only`，被本地改动挡住就留着并在交回里说。
- 云端 CI 只在合并进主干后跑兜底，不用守着。合并前先看主干最近一遍（`gh run list --branch main`），红的先处理：改动造成的修或回退那次合并，runner 自己崩的重跑。
- `cuepad --help` 是命令行唯一文档。

## 护栏

- 冻结：两份 README 与落地页（`landing/`）现在是占位，`design/readme/` 的截图不重拍；等用户说大更新落地再重写，期间只改 lint 要求与 `Palette` 同步的 `landing/src/styles/base.css` 令牌。
- 对外发布只在用户明确要求时做（apple/scripts/AGENTS.md）。
- 本机构建不开真实资料库：一打开就会升级结构、改写数据并同步出去，正式版之后就打不开了。看真实数据只用只读副本（apple/scripts/AGENTS.md「真实数据复现」）。
- 测试只用替身，不向其他应用发键鼠事件；全局热键真按下去的那一下只能人工验证。
- 用户可见行为的端到端测试从 `Workspace` 的方法走（界面的按钮、菜单调的就是它），断言库、提示与回复框，放在 `App/Tests/UI` 的流程测试里；接线与长相用交互验收（apple/scripts/AGENTS.md）。
- 跨会话、暂不做的待办在 GitHub Issues（`gh issue list`）。

## 文档

文档不是现状证据，现状以代码、脚本与测试为准。文档只装三类：代码看不出的理由与否决项、跨模块的叫法（WORDS.md）、要在第三方控制台上手工做的事。踩到的坑修成脚本的报错、lint 或代码旁的一句注释，不记进文档；不写版本史、复盘、源码镜像，以及 `xc.sh help`、脚本头注释、类型头注释里查得到的东西。新增 Markdown 要进 `lint_docs.py` 的清单。

改哪里，先读最近那一层的 `AGENTS.md`：

- 发布、签名、CloudKit 结构部署，看真实数据、通知验收、查日志 → [apple/scripts/AGENTS.md](apple/scripts/AGENTS.md)
- 给界面加字、补英文 → [apple/App/Strings/AGENTS.md](apple/App/Strings/AGENTS.md)
- Pi 桥扩展的协议约定 → [CueBridge README](apple/CuePadKit/Sources/CueBridge/README.md)
- 中转的部署 → [relay/README.md](relay/README.md)
