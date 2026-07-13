# CuePad 模块索引

产品定位与功能见 [README.md](README.md)；开发命令、架构要点与验收环境事实见 [docs/development.md](docs/development.md)。

| 模块 | 职责 |
| --- | --- |
| `src/lib/db/` | SQLite repository：projects / cards / tasks / tags / trash / settings / search，`executeBatch` 事务批量 |
| `src/lib/workspace/` | 工作区 UI 与状态：`store.svelte.ts`（当前项目/全局收藏/任务单一事实源）、`editor.svelte.ts`（沉浸编辑）、`dispatch.ts`（复制/投送入口）、`CardBoard.svelte`（横向项目栏 + 单项目卡片墙）、`TaskStack.svelte`（全局悬浮任务）、命令面板、设置、回收站 |
| `src/lib/editor/` | CodeMirror 封装、轻量装饰（decorations）、块系统（角色分隔线/编号/排版复制/块快捷键，`segments.ts` `blocks.ts`）、变量模板（`variables.ts`）、自动保存、本地备份 |
| `src/lib/shell/` | 全局快捷键注册与 accelerator 编解码 |
| `src/lib/ui/` | 通用 UI 原子组件（Button / Toast / Dialog / 色板 / Mascot 吉祥物等） |
| `src/lib/assets/` | 品牌 IP 透明底定稿（空状态/关于页用）；源图与 logo 定稿在 `design/final/` |
| `src-tauri/src/lib.rs` | 托盘、默认全局热键（Rust 侧 handler）、关闭=隐藏、quit 命令 |
| `src-tauri/src/dispatch.rs` | macOS 前台应用追踪、运行应用枚举与一键投送：NSWorkspace、Accessibility、CGEvent `Cmd+V` |
| `src-tauri/migrations/` | SQLite schema 迁移 |
| `tests/` | bun test（repository，含 tasks / segments / autosave / backup / accelerator / search） |
| `e2e/` | 无头视觉验收：Playwright WebKit + 可变 Tauri IPC mock，覆盖工作区、悬浮任务、动效与响应式布局（`bun run test:e2e`） |
| `e2e-tauri/` | 真实 Tauri 验收：WDIO 内嵌 WebDriver，覆盖权限、SQLite v5 tasks、Pin/Star、三类拖拽与跨进程恢复；1×1 非交互窗 + 独立 identifier，不抢焦点（`bun run test:tauri`） |
