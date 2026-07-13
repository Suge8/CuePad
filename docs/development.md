# CuePad 开发文档

技术栈：Electron 37 + SvelteKit (Svelte 5) + TypeScript + Tailwind CSS 4 + Bits UI + CodeMirror 6 + SQLite（Electron 主进程 `node:sqlite`）。Tauri 壳仅保留作迁移期基线，计划在 Electron 能力等价后下线。

## 常用命令

```bash
bun run dev:electron  # Electron 桌面开发模式
bun run test:electron # 真实 Electron + SQLite 验收
bun run check         # svelte-check 类型检查
bun test              # Bun 单元测试
bun run test:e2e      # 无头视觉验收（Playwright WebKit，见下）
bun run test:tauri    # 迁移期 Tauri 基线验收
bun run lint          # eslint
bun run build         # 前端产物构建
```

## 架构要点

- **数据层**（`src/lib/db/`、`electron/db.ts`）：repository 保持运行时无关；renderer 只经 `window.cuepad.sql` 调用，SQLite 连接、迁移和 `BEGIN IMMEDIATE…COMMIT` 真事务都在 Electron 主进程。schema 见根目录 `migrations/`；首次启动在目标库不存在时复制旧 Tauri `.db`/`.db-wal`/`.db-shm`，源文件不改不删，并把 `_sqlx_migrations` 的成功版本继承到 `schema_migrations`。v5 `tasks` 仅含正文、项目关联、基础顺序、完成时间和时间戳。
- **状态层**：`workspace`（`src/lib/workspace/store.svelte.ts`）是工作区单一事实源（`WorkspaceView`、项目/卡片/任务/标签/回收站、面板、主题、快捷键）；`editor`（`editor.svelte.ts`）管沉浸编辑草稿。主界面由横向项目栏和单项目卡片墙（`CardBoard.svelte`）组成；桌面端项目栏和卡片层均使用完整工作区宽度，任务区作为可收起浮层覆盖右上区域，不永久挤压卡片布局。`projectId === null` 是虚拟「未归档」（数据库中无项目行）：首个空工作区草稿默认进入未归档；选择未归档后可继续新建；编辑器可把任意卡片移入未归档；恢复仍隶属已删除项目的单卡时也会进入未归档。当前项目只写入 `cuepad:active-project`，加载后用 SQLite 项目列表校验；失效时按「有卡的未归档 → 首个置顶项目 → 首个普通项目 → 未归档」回退。项目置顶与卡片收藏只划分稳定展示分区，`mergePartitionOrder` 把分区内拖拽写回原 `sort_order` 槽位。
- **悬浮任务**（`tasks.ts` / `TaskStack.svelte`）：SQLite `tasks` 是持久事实源，`workspace.tasks` 是全局响应式缓存，不随 `WorkspaceView` 过滤。活动区按 `sort_order`，完成区按 `completed_at` 新到旧；完成/恢复不改基础顺序。每个任务只有一条串行写链，在途更新合并最终 patch，失败后按 id 恢复 SQLite 状态。排序由 `TaskStack` 的 Pointer Capture 按活动行中点计算插入槽位，不经过 HTML5 DnD 或 `elementFromPoint`；排除源任务后只渲染一条独立横线，始终表示松手后的最终任务间隙。项目软删除保留 `project_id` 并显示「项目已回收」；恢复项目自动复原，硬删除或清空回收站由 `ON DELETE SET NULL` 置空。任务完成可逆，永久删除采用两击确认，不进入项目/卡片回收站；桌面端任务区从项目栏下方开始，`56rem` 以下入口直接参与顶栏 actions 排版，展开层仍固定在工作区右侧。
- **Motion contract**（`src/lib/motion.ts` / `src/routes/layout.css`）：Svelte transition、WAAPI icon switch 和 FLIP 共用时长、缓动与减动分支。任务新增/完成/恢复/删除只动画对应 `.task-motion`，项目菜单和窄窗入口独立进出；父任务栈不整体闪动。`prefers-reduced-motion` 取消位移、缩放和 FLIP，只保留状态颜色、焦点与淡变。
- **块系统**（`src/lib/editor/segments.ts` / `blocks.ts` / `decorations.ts`）：正文永远是纯文本，块是视图概念。分隔线四种：`---split---`（普通）、`---ask---`、`---answer---`、`---system---`，定义其后一段角色；点击块头循环切换角色。卡片级编号风格（`cards.numbering`：none/decimal/alpha/cjk）不写入正文，渲染（decoration badge，经 `numberingFacet` + Compartment 注入）与复制（`formatSegments` 确定性排版：段 trim + `## 1`/`## Q1` 段头）时生成。编辑器内快捷键：`Shift+Enter` 光标处切块、`Cmd+↑/↓` 跨块跳转（无块可跳时回落系统的文档首/尾）、`Cmd+Shift+C` 复制当前块。
- **自动保存**（`src/lib/editor/autosave.ts`）：buffer（debounce）→ queue → 单一 drain 循环串行写；失败 patch 放回队列，`backup.ts` 在每次写库前先落 localStorage 快照，成功即清。Autosave 实例按卡创建，切卡先 flush。
- **软删除**：项目删除与其卡片共享 `delete_batch_id`，恢复/永久删除按批次处理；恢复卡片时若所属项目仍在回收站则移入收件箱。
- **桌面壳**（`electron/main.ts` / `tray.ts` / `shortcuts.ts`）：关闭窗口只隐藏，托盘、Dock `activate` 与全局热键都由主进程恢复窗口；托盘「设置」经受限事件桥打开设置页。快捷键仍存 W3C code accelerator（如 `Alt+Space`、`Control+Alt+KeyU`），仅在注册边界转成 Electron accelerator；主进程持有注册表和固定显隐 handler，renderer 只负责自定义键的串行切换、持久化与失败回滚。剪贴板、版本、数据库路径和 Finder 定位同样只经 `window.cuepad` 类型桥调用。
- **一键投送（macOS-only）**（`src-tauri/src/dispatch.rs` / `src/lib/workspace/dispatch.ts`）：renderer 已只调用 `window.cuepad.dispatch`；当前 Electron 主进程在 sidecar 接入前明确返回 `DISPATCH_TARGET_UNAVAILABLE`，不静默回退，真实实现仍保留在迁移期 Rust 基线。Rust 订阅 `NSWorkspaceDidActivateApplicationNotification`，从通知 `userInfo[NSWorkspaceApplicationKey]` 提取被激活应用（事实源是通知携带的对象；回调时刻的全局 frontmost 在快速切换下会丢事件），持续记录最近一个非 CuePad 前台应用的 PID、bundle id 与本地化名，不轮询。默认投送到该应用；`dispatch_targets` 按需读取当前运行的普通应用，用户可在按钮旁按 bundle id 固定目标，偏好存 localStorage `cuepad:dispatch-target`，应用重启后仍可解析新 PID。固定目标未运行时返回错误，禁止静默回退。`dispatch_text` 先检查 Accessibility 授权并写剪贴板，再隐藏主窗口、激活目标 `NSRunningApplication`，最后用 CGEvent 向目标 PID 合成 `Cmd+V`；定向发送避免激活尚未完成时把按键发回 CuePad。投送进入该应用当前 first responder，因此用户切来 CuePad 前必须先聚焦具体输入框。未授权返回 `ACCESSIBILITY_PERMISSION_REQUIRED`，前端明确引导到「系统设置 → 隐私与安全性 → 辅助功能」，不静默降级。自定义 command 不受插件 ACL 限制。
- **变量模板**（`src/lib/editor/variables.ts` / `VariableFillDialog.svelte`）：变量语法与 CodeMirror 高亮共用 `VARIABLE_PATTERN`；复制和 dispatch 共用同一填充入口。每卡填写值只存 localStorage `cuepad:vars:<cardId>`，不进入 SQLite 或正文。
- **键盘分层**：`Cmd/Ctrl+F` 在 page 层 window capture 拦截（先于 CodeMirror）；快捷键录制绑定在录制按钮自身；面板 Escape 由常驻挂载的 CommandPalette window handler 先处理，`preventDefault` 后 FocusEditor 跳过退出。
- **权限**（`src-tauri/capabilities/default.json`）：多个插件的 `default` 权限集是空的（clipboard、global-shortcut），新增插件能力时必须显式加 `allow-*`，否则真实 App 中被 ACL 拒绝、dev 页面不报错。

## 品牌资产

- 定稿源图在 `design/final/`（logo、lockup、app icon、IP 姿势）；应用内透明底 IP 在 `src/lib/assets/`，由 `src/lib/ui/Mascot.svelte` 统一渲染（悬浮微动 + `popRise` 入场，见 `src/lib/motion.ts`）。
- 触点原则：插画只放体验边缘（空态/错误/成功/首启），不进正文工作区。姿势→场景：empty=首屏空态、welcome=收藏空/首启欢迎卡（`WelcomeCard.svelte`，localStorage `cuepad:welcomed`）、search=无结果、trash/clean=回收站空/刚清空、error=加载失败（`workspace.loadError` + 重试）、hello=设置页脚。四角星（`Sparkle.svelte`）是最小品牌单元：success toast 星尘迸发、空态点缀；微动效全部尊重 `prefers-reduced-motion`。
- 重新生成（macOS 本机，无外部依赖）：`design/tools/cutout.swift` 用 Vision 抠图；`design/tools/icon.swift` 从黑白 logo 提取 mark，合成 1024 squircle（喂 `bun tauri icon` 生成全套）与 `src-tauri/icons/tray.png`（44px 黑+alpha 模板图，`lib.rs` 中 `icon_as_template(true)`）。Electron 从该图生成 macOS 推荐的 16px `trayTemplate.png` 与 32px `trayTemplate@2x.png`；缺少密度后缀会被当成 44pt，导致菜单栏图标放大。

## 自动验收

自动验收固定分三层，不再用 AppleScript / AX / CGEvent 驱动 CuePad：

- `bun run test:e2e`：Playwright headless WebKit + 完整 `window.cuepad` 桌面桥 mock（`e2e/`），负责视觉、布局、工作区与任务 CRUD、剪贴板/设置事件/快捷键/投送前端路径、完整 pointerup 命中、独立动效和快速回归。
- `bun run test:electron`：Playwright Electron（`e2e-electron/`），使用隔离 userData 验证安全 preload、全局快捷键注册与重启恢复、系统剪贴板、close=hide、拖拽区、空库迁移、真实 CRUD/事务，以及旧 Tauri WAL 数据继承与源文件不变；托盘模板图和菜单回调由 `bun test` 覆盖。
- `bun run test:tauri`：保留迁移前 Tauri 基线验收代码与历史证据；当前 migration 已移出 `src-tauri/`，不属于 Electron 迁移期间的每轮回归，待 G5 随旧壳一并下线。

`bun run test:tauri` 全自动覆盖两组真实运行时链路：① `AXIsProcessTrusted() == false` → `dispatch_text` 返回 `ACCESSIBILITY_PERMISSION_REQUIRED` → 权限引导 Toast；② UI 创建项目/卡片/任务 → Pin / Star → 三类分区拖拽 → SQLite 落库 → 新进程恢复任务正文、项目分配、完成状态和顺序。隔离规则：

1. **TCC 责任链**：终端会话直接 spawn、`open`、legacy `launchctl submit` 启动的进程均归责宿主终端并继承其辅助功能信任；只有 `launchctl bootstrap` 的 LaunchAgent 责任进程是服务自身（`e2e-tauri/launch.sh`），才能测到真实未授权分支。
2. **身份与数据隔离**：测试构建用独立 identifier `com.sugeh.cuepad.wdio`；`run.zsh` 每轮只清空该 identifier 的数据库与 WebKit 状态，永不触碰日常 CuePad 数据。
3. **桌面零输入干扰**：测试窗固定为屏幕边角的 1×1 可见窗，`focusable=false` 且忽略鼠标事件。不能移到屏外或隐藏，否则 WebKit 会挂起任务队列；该窗口不抢焦点、不接收点击。
4. **端口与并发**：WebDriver 插件只在 `TAURI_WEBDRIVER_PORT` 存在时注册，普通 debug/dev 实例不监听端口；每次运行分配随机空闲端口。入口 `run.zsh` 用内核文件锁串行完整管线，未知端口占用明确报错，不盲杀。
5. **构建隔离**：测试使用 `.svelte-kit-wdio` / `build-wdio`，与常驻 dev 和普通 `bun run build` 零共享写路径；内核锁覆盖「前端构建 → Tauri 构建 → WDIO」。

踩坑实录：原生 WebDriver element click 在微型 WKWebView 中会挂起，交互统一经 `browser.execute` 派发 DOM 语义；1×1 窗没有可靠的 `elementFromPoint` 命中面，WDIO 对项目/卡片调用 sveltednd 的 `pointerdrop-on-container`，任务只派发 pointer move/up 坐标。Playwright 必须用 `page.mouse` 锁定桌面鼠标链路，不能用触控 PointerEvent 代替。真实窗口证明 WKWebView 物理鼠标不会稳定进入 sveltednd 的任务起拖链路，且 Pointer Capture 下元素命中方向不一致；任务因此改用组件内状态机，按其他活动行的垂直中点计算唯一插入槽位。向上槽位线位于目标上方，向下位于目标下方或列表末尾，均落在任务间隙；测试还会禁用 `elementFromPoint` 并检查首条上方线未被滚动视口裁切。关闭编辑器会重新挂载 `TaskStack`，窄窗初始 `#task-panel` 只是瞬时节点；WDIO 必须等待可见窄窗入口并打开，最终只以 `[data-task-add-trigger]` 作为面板就绪信号。Tauri internals 在 WDIO 隔离 JS world 中被冻结，无法订阅 SQL Promise，因此仅对真实 SQLite 最终状态做 50ms、最多 5s 的有界观察；这不是动画采样。Node 26 禁止头与 `@wdio/native-utils` 版本坑分别由 `transformRequest` 和 override 固定。

只有“必须改变当前 GUI session”的 OS 路径（授权后的目标应用激活、CGEvent 粘贴、物理全局热键）以及主观动效手感保留人工 smoke。自动验收期间禁止系统级合成鼠标/键盘；用户正在操作桌面时不得启动会抢焦点的验证。Playwright 经验：

1. 测试后缀 `.e2e.ts`（避开 `bun test` 的 `*.test/*.spec` 扫描）；必须通过 `bun run test:e2e` 启动——`e2e/run.ts` 用标准库为每次调用分配空闲端口和 `/tmp/cuepad-e2e/<run-id>/` 独立目录，并把默认 dep cache 只读复制为种子；`vite.config.ts` 随后将 `cacheDir` 指向该 run 私有副本。端口、产物、Vite 预构建写入三者均隔离，避免并发实例共享 `node_modules/.vite` 触发 full-reload。E2E 环境还条件性忽略整个 `.svelte-kit/` 与 `build/`：`bun run build` 会重写 generated/types/output 等多个子目录，只忽略 output 不充分；普通 dev 不忽略 `.svelte-kit/`，路由结构热更新不受影响。
2. vite 需显式 `--host 127.0.0.1`（默认绑 IPv6 `::1`，baseURL 127.0.0.1 连不上）。
3. `expect(locator).toBeHidden()` 对解析出多元素的泛化 locator（如 `getByRole('dialog')`）会立即 strict violation 不重试；弹层 outro 重叠窗口内两个 dialog 短暂共存是预期动画行为，退场断言必须用具名 dialog。
4. 动效行为断言用记录式而非实时采样：`e2e/animation-recorder.js`（init script patch `Element.prototype.animate`，记入 `window.__ANIM_LOG__` 并派发 `cuepad:animation` 事件）；断言先订阅事件再复查已有日志，不做一次性竞态读取，也不主动轮询。实时 `getAnimations()` 在 140-220ms 过渡窗口内有固有竞态。四个口径陷阱：(a) svelte 单次过渡会创建 dummy+正式两条同关键帧动画，累计计数区分不了进/出场；退场断言必须依次等待当前元素 `getAnimations().finished`（避免 intro/outro 合并为一次反转）、标记日志、预先启动事件断言、再触发关闭；Toast 要在截图与 2.2s 自动隐藏前完成标记/订阅；(b) 断言取「含预期属性的记录 ≥ n」而非精确计数；(c) hover/press 后的 computed style 首帧仍是过渡起点值（即使 duration 0.01ms），必须双 rAF 等稳定后采样，否则假阴性；(d) 事后才订阅事件无法证明方向，所有退场必须使用上述预订阅顺序。断言改动后用「篡改必挂、恢复必过」验证有效性。正常模式进/出场含 `transform`，减动模式（`emulateMedia({ reducedMotion: 'reduce' })`）只应有 `opacity`。

## 无头验收环境事实（重要）

历轮验收在无人值守环境反复踩到，均为 WebKit/macOS 行为而非产品 bug：

1. **显示器睡眠/锁屏时 WebKit 冻结动画时间线与任务队列**（`document.timeline` 不推进、rAF/输入事件停滞、WAAPI onfinish 不触发）→ svelte 状态回写、outro 和表单输入会出现假失败。`e2e/run.ts` 在 macOS 自动触发 `caffeinate -u -t 3`，并用 `caffeinate -d` 包住完整 Playwright 进程；DOM 断言仍优先换成状态层断言。
2. 窗口遮挡/隐藏 ~10s 后 WebKit 挂起整个 page task queue（timer 冻结、MessageChannel 丢消息）。
3. 合成键盘事件不触发系统全局热键（OS 限制），热键验证只能物理按键。
4. 本机 AX 拿不到 tauri dev 窗口（count 恒 0），窗口可见性断言用 Rust `is_visible` 或 CGWindowList。
5. `document.visibilityState` 反映遮挡而非窗口可见性，不可作显隐断言。
