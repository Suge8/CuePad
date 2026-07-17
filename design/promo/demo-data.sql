-- CuePad 演示数据（宣传物料共用，可重跑）
-- 用法见 make-demo-db.sh；时间戳相对 now 錯开制造真实感

-- 主题浅色（截深色时改为 '"dark"'）
UPDATE app_settings SET value = '"light"' WHERE key = 'theme';

-- ── 项目 ──────────────────────────────────────────────
INSERT INTO projects (id, name, icon, color, sort_order, is_pinned, created_at, updated_at) VALUES
  (1, 'CuePad',   'sparkles', '#7a76e3', 1, 1, (strftime('%s','now') - 86400*21) * 1000, (strftime('%s','now') - 3600) * 1000),
  (2, '行情看板', 'terminal', '#4f8ce8', 2, 0, (strftime('%s','now') - 86400*14) * 1000, (strftime('%s','now') - 7200) * 1000),
  (3, '博客引擎', 'pen',      '#55ab6e', 3, 0, (strftime('%s','now') - 86400*9)  * 1000, (strftime('%s','now') - 86400) * 1000),
  (4, '爬虫管道', 'braces',   '#e78a3a', 4, 0, (strftime('%s','now') - 86400*5)  * 1000, (strftime('%s','now') - 43200) * 1000);

-- ── 卡片：CuePad（主角项目）──────────────────────────
INSERT INTO cards (id, project_id, title, body, sort_order, is_favorite, created_at, updated_at) VALUES
  (1, 1, '代码评审', '## 评审要求

请评审当前 diff，重点检查：

- 竞态：共享状态是否有同步保护
- 错误路径：IO / IPC 失败会不会静默吞错
- 死代码：这次改动是否留下失效分支

结论按「必须修 / 建议改 / 可以过」分级，每条给出文件与行号。', 1, 1, (strftime('%s','now') - 86400*20) * 1000, (strftime('%s','now') - 3600) * 1000),

  (2, 1, '重构模块', '把 {{模块路径}} 重构为 {{目标形态}}。

约束：

- 不改对外接口，现有测试全绿
- 每步一个 commit，可独立回滚
- 禁止顺手改无关代码

完成后总结改动点、行数变化和已知风险。', 2, 1, (strftime('%s','now') - 86400*18) * 1000, (strftime('%s','now') - 7200) * 1000),

  (3, 1, '修 flaky 测试', 'e2e 里 {{用例名}} 偶发超时。

先复现 10 次统计失败率，再最小化用例定位根因。
禁止加 sleep 掩盖，找到真正的等待语义再修，修完连续跑 20 次验证。', 3, 0, (strftime('%s','now') - 86400*12) * 1000, (strftime('%s','now') - 86400*2) * 1000),

  (4, 1, '发布前检查', 'bun run check && bun run lint && bun test

---split---

bun run test:e2e && bun run test:electron

---split---

bun run package:app && bun run test:package
codesign --verify --deep --strict release/mac-arm64/CuePad.app', 4, 0, (strftime('%s','now') - 86400*10) * 1000, (strftime('%s','now') - 86400*3) * 1000),

  (5, 1, '写发布说明', '根据 v0.2.0 以来的 git log 写发布说明：

- 用户能感知的变化放最前面
- 修复单独列「修复」小节，内部重构不写
- 语气克制，不吹

输出为 Markdown，直接可贴 GitHub Release。', 5, 0, (strftime('%s','now') - 86400*6) * 1000, (strftime('%s','now') - 86400) * 1000);

-- ── 卡片：其他项目（供全局收藏与搜索演示）──────────────
INSERT INTO cards (id, project_id, title, body, sort_order, is_favorite, created_at, updated_at) VALUES
  (6, 2, 'SQL 慢查询优化', '分析 {{表名}} 上这条慢查询：

1. 先 EXPLAIN QUERY PLAN，确认是否走索引
2. 给出索引方案与代价（写放大 / 空间）
3. 改写查询本身是否有更短路径

结论附实测耗时对比。', 1, 1, (strftime('%s','now') - 86400*13) * 1000, (strftime('%s','now') - 86400*2) * 1000),

  (7, 2, 'K 线组件性能', '图表在 5000 根 K 线时掉帧。

先用 Performance 面板录一段定位热点，再谈方案；
禁止未度量就上 memo / 虚拟化。', 2, 0, (strftime('%s','now') - 86400*11) * 1000, (strftime('%s','now') - 86400*4) * 1000),

  (8, 3, '文章润色', '润色 {{文章路径}}：

- 删掉空泛形容词和 AI 味套话
- 长句拆短，每段只讲一件事
- 保留我的口语习惯，不要变成官腔

改动处逐条列出理由。', 1, 1, (strftime('%s','now') - 86400*8) * 1000, (strftime('%s','now') - 86400) * 1000),

  (9, 3, 'SEO 检查', '检查当前文章的 title / description / heading 结构，
给出 3 条以内的修改建议，不要堆关键词。', 2, 0, (strftime('%s','now') - 86400*7) * 1000, (strftime('%s','now') - 86400*3) * 1000),

  (10, 4, '反爬分析', '目标站点开始返回 403。

抓最近一次成功和失败的完整请求头对比，
判断是 UA 指纹、频率还是 Cookie 失效，给最小改动方案。', 1, 0, (strftime('%s','now') - 86400*4) * 1000, (strftime('%s','now') - 43200) * 1000),

  (11, 4, '数据清洗规则', '为 {{数据源}} 写清洗规则：

- 空值与异常值的处理策略要显式写出
- 每条规则配一个反例测试

输出为可直接运行的脚本。', 2, 0, (strftime('%s','now') - 86400*3) * 1000, (strftime('%s','now') - 86400) * 1000),

-- 收件箱（未归档）
  (12, NULL, '灵感：命令面板加最近使用', '搜索面板顶部加「最近打开」分区，最多 5 条，
按 updated_at 排序。先出原型看看会不会挤。', 1, 0, (strftime('%s','now') - 86400*2) * 1000, (strftime('%s','now') - 10800) * 1000);

-- ── 标签 ──────────────────────────────────────────────
INSERT INTO tags (id, name, created_at, updated_at) VALUES
  (1, '评审',  (strftime('%s','now') - 86400*20) * 1000, (strftime('%s','now') - 86400*20) * 1000),
  (2, '模板',  (strftime('%s','now') - 86400*18) * 1000, (strftime('%s','now') - 86400*18) * 1000),
  (3, '发布',  (strftime('%s','now') - 86400*10) * 1000, (strftime('%s','now') - 86400*10) * 1000);

INSERT INTO card_tags (card_id, tag_id, created_at) VALUES
  (1, 1, (strftime('%s','now') - 86400*20) * 1000),
  (2, 2, (strftime('%s','now') - 86400*18) * 1000),
  (6, 2, (strftime('%s','now') - 86400*13) * 1000),
  (8, 2, (strftime('%s','now') - 86400*8)  * 1000),
  (4, 3, (strftime('%s','now') - 86400*10) * 1000),
  (5, 3, (strftime('%s','now') - 86400*6)  * 1000);

-- ── 悬浮任务 ──────────────────────────────────────────
INSERT INTO tasks (id, content, project_id, sort_order, completed_at, created_at, updated_at) VALUES
  (1, '回归卡片拖拽 e2e', 1, 1, NULL, (strftime('%s','now') - 86400*2) * 1000, (strftime('%s','now') - 86400*2) * 1000),
  (2, '补 K 线图空状态', 2, 2, NULL, (strftime('%s','now') - 86400) * 1000, (strftime('%s','now') - 86400) * 1000),
  (3, '写 v0.3 发布说明', NULL, 3, NULL, (strftime('%s','now') - 43200) * 1000, (strftime('%s','now') - 43200) * 1000),
  (4, '修复剪贴板竞态', 1, 4, (strftime('%s','now') - 7200) * 1000, (strftime('%s','now') - 86400*3) * 1000, (strftime('%s','now') - 7200) * 1000);
