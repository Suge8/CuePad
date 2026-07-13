// 桌面桥 mock：SQL 走 window.cuepad.sql，其余 G3 尚未迁移的能力仍走 Tauri invoke。
// SQL 按查询特征路由到静态 fixture——无头视觉验收不需要真数据库。
(() => {
	const now = 1783470918000;

	const project = (id, name, icon, color, sort, isPinned = 0) => ({
		id,
		name,
		icon,
		color,
		sort_order: sort,
		is_pinned: isPinned,
		deleted_at: null,
		delete_batch_id: null,
		delete_source: null,
		delete_source_id: null,
		created_at: now,
		updated_at: now
	});

	const card = (id, projectId, title, body, extra = {}) => ({
		id,
		project_id: projectId,
		title,
		body,
		sort_order: id,
		is_favorite: 0,
		numbering: 'none',
		deleted_at: null,
		delete_batch_id: null,
		delete_source: null,
		delete_source_id: null,
		created_at: now,
		updated_at: now,
		...extra
	});

	const task = (id, content, projectId, sortOrder, completedAt = null) => ({
		id,
		content,
		project_id: projectId,
		sort_order: sortOrder,
		completed_at: completedAt,
		created_at: now,
		updated_at: now
	});

	const PROJECTS = [
		project(1, 'Alpha', 'rocket', '#4f8ce8', 1),
		project(2, 'Beta', 'zap', '#55ab6e', 2, 1)
	];

	const CARDS = [
		card(
			1,
			1,
			'Alpha 发布检查单',
			'开场白：介绍 {{产品名}} 的核心能力\n---ask---\n用户最关心的三个问题是什么？\n---answer---\n性能、隐私、价格。',
			{ is_favorite: 1, numbering: 'decimal' }
		),
		card(2, 1, null, '快速草稿：明天的演示流程'),
		card(3, 2, 'Beta 提示词', '给模型的系统提示词草稿'),
		card(4, null, null, '收件箱里的灵感')
	];

	const TASKS = [
		task(1, '检查明天演示环境', 1, 0),
		task(2, '补充 Beta 提示词', 2, 1),
		task(3, '整理本周灵感', null, 2, now - 10_000)
	];

	const DATABASE_STATE_KEY = 'cuepad:e2e-database';
	try {
		const saved = JSON.parse(localStorage.getItem(DATABASE_STATE_KEY) ?? 'null');
		for (const row of saved?.projects ?? []) {
			const projectRow = PROJECTS.find((projectItem) => projectItem.id === row.id);
			if (projectRow) Object.assign(projectRow, row);
		}
		for (const row of saved?.cards ?? []) {
			const cardRow = CARDS.find((cardItem) => cardItem.id === row.id);
			if (cardRow) Object.assign(cardRow, row);
		}
		if (Array.isArray(saved?.tasks)) TASKS.splice(0, TASKS.length, ...saved.tasks);
	} catch {
		localStorage.removeItem(DATABASE_STATE_KEY);
	}

	function persistDatabase() {
		localStorage.setItem(
			DATABASE_STATE_KEY,
			JSON.stringify({ projects: PROJECTS, cards: CARDS, tasks: TASKS })
		);
	}

	const TAGS = [
		{ id: 1, name: 'demo', color: '#e2679c', created_at: now, updated_at: now }
	];

	const SETTINGS = [
		{ key: 'theme', value: '"system"', created_at: now, updated_at: now },
		{ key: 'globalShortcut', value: 'null', created_at: now, updated_at: now }
	];

	function routeSelect(query, values) {
		if (query.includes('FROM app_settings')) {
			return values && values.length > 0
				? SETTINGS.filter((row) => row.key === values[0])
				: SETTINGS;
		}
		if (query.includes('FROM card_tags')) return [];
		if (query.includes('FROM tags')) return TAGS;
		if (query.includes('FROM projects')) {
			let rows = [...PROJECTS];
			if (query.includes('deleted_at IS NULL')) rows = rows.filter((row) => row.deleted_at === null);
			if (query.includes('deleted_at IS NOT NULL')) rows = rows.filter((row) => row.deleted_at !== null);
			if (query.includes('WHERE id = $1')) rows = rows.filter((row) => row.id === values[0]);
			return rows.sort((left, right) => left.sort_order - right.sort_order || left.id - right.id);
		}
		if (query.includes('FROM cards') || query.includes('cards.*')) {
			let rows = [...CARDS];
			if (query.includes('deleted_at IS NULL')) rows = rows.filter((row) => row.deleted_at === null);
			if (query.includes('deleted_at IS NOT NULL')) rows = rows.filter((row) => row.deleted_at !== null);
			if (query.includes('WHERE id = $1')) rows = rows.filter((row) => row.id === values[0]);
			return rows.sort((left, right) => left.sort_order - right.sort_order || left.id - right.id);
		}
		if (query.includes('FROM tasks')) {
			let rows = [...TASKS];
			if (query.includes('WHERE id = $1')) rows = rows.filter((row) => row.id === values[0]);
			if (query.includes('WHERE completed_at IS NULL')) rows = rows.filter((row) => row.completed_at === null);
			return rows.sort((left, right) => {
				if (left.completed_at === null && right.completed_at !== null) return -1;
				if (left.completed_at !== null && right.completed_at === null) return 1;
				if (left.completed_at === null) return left.sort_order - right.sort_order || left.id - right.id;
				return right.completed_at - left.completed_at || right.id - left.id;
			});
		}
		return [];
	}

	function assignmentValue(query, values, column) {
		const match = query.match(new RegExp(`${column} = \\$([0-9]+)`));
		return match ? values[Number(match[1]) - 1] : undefined;
	}

	function routeExecute(query, values) {
		let lastInsertId = 100;
		if (query.startsWith('INSERT INTO tasks')) {
			lastInsertId = TASKS.reduce((max, row) => Math.max(max, row.id), 0) + 1;
			const activeOrders = TASKS.filter((row) => row.completed_at === null).map((row) => row.sort_order);
			const sortOrder = activeOrders.length > 0 ? Math.min(...activeOrders) - 1 : 0;
			TASKS.push(task(lastInsertId, values[0], values[1], sortOrder));
			TASKS.at(-1).created_at = values[2];
			TASKS.at(-1).updated_at = values[2];
		}
		if (query.startsWith('UPDATE projects SET') && query.includes('is_pinned')) {
			const row = PROJECTS.find((projectRow) => projectRow.id === values.at(-1));
			if (row) {
				row.is_pinned = values[0];
				row.updated_at = values.at(-2);
			}
		}
		if (query.startsWith('UPDATE cards SET') && query.includes('is_favorite')) {
			const row = CARDS.find((cardRow) => cardRow.id === values.at(-1));
			if (row) {
				row.is_favorite = values[0];
				row.updated_at = values.at(-2);
			}
		}
		if (query.startsWith('UPDATE tasks SET') && !query.includes('sort_order')) {
			const row = TASKS.find((taskRow) => taskRow.id === values.at(-1));
			if (row) {
				const content = assignmentValue(query, values, 'content');
				const projectId = assignmentValue(query, values, 'project_id');
				const completedAt = assignmentValue(query, values, 'completed_at');
				const updatedAt = assignmentValue(query, values, 'updated_at');
				if (content !== undefined) row.content = content;
				if (projectId !== undefined) row.project_id = projectId;
				if (completedAt !== undefined) row.completed_at = completedAt;
				if (updatedAt !== undefined) row.updated_at = updatedAt;
			}
		}
		if (query.includes('UPDATE projects SET sort_order')) {
			for (let offset = 0; offset < values.length; offset += 3) {
				const row = PROJECTS.find((projectRow) => projectRow.id === values[offset + 2]);
				if (row) {
					row.sort_order = values[offset];
					row.updated_at = values[offset + 1];
				}
			}
		}
		if (query.includes('UPDATE cards SET sort_order')) {
			for (let offset = 0; offset < values.length; offset += 3) {
				const row = CARDS.find((cardRow) => cardRow.id === values[offset + 2]);
				if (row) {
					row.sort_order = values[offset];
					row.updated_at = values[offset + 1];
				}
			}
		}
		if (query.includes('UPDATE tasks SET sort_order')) {
			for (let offset = 0; offset < values.length; offset += 3) {
				const row = TASKS.find((taskRow) => taskRow.id === values[offset + 2]);
				if (row) {
					row.sort_order = values[offset];
					row.updated_at = values[offset + 1];
				}
			}
		}
		if (query.includes("SET deleted_at = $1") && query.includes('UPDATE projects')) {
			const projectId = values[2];
			const row = PROJECTS.find((projectRow) => projectRow.id === projectId);
			if (row) {
				row.deleted_at = values[0];
				row.delete_batch_id = values[1];
				row.delete_source = 'project';
				row.delete_source_id = projectId;
				row.updated_at = values[0];
			}
			for (const cardRow of CARDS) {
				if (cardRow.project_id !== projectId || cardRow.deleted_at !== null) continue;
				cardRow.deleted_at = values[0];
				cardRow.delete_batch_id = values[1];
				cardRow.delete_source = 'project';
				cardRow.delete_source_id = projectId;
				cardRow.updated_at = values[0];
			}
		}
		if (query.includes('SET deleted_at = NULL') && query.includes('UPDATE projects')) {
			const projectId = values[1];
			const row = PROJECTS.find((projectRow) => projectRow.id === projectId);
			if (row) {
				row.deleted_at = null;
				row.delete_batch_id = null;
				row.delete_source = null;
				row.delete_source_id = null;
				row.updated_at = values[0];
			}
			for (const cardRow of CARDS) {
				if (cardRow.project_id !== projectId || cardRow.delete_source !== 'project') continue;
				cardRow.deleted_at = null;
				cardRow.delete_batch_id = null;
				cardRow.delete_source = null;
				cardRow.delete_source_id = null;
				cardRow.updated_at = values[0];
			}
		}
		if (query.includes('DELETE FROM tasks WHERE id')) {
			const index = TASKS.findIndex((taskRow) => taskRow.id === values[0]);
			if (index >= 0) TASKS.splice(index, 1);
		}
		if (query.includes('DELETE FROM projects WHERE id =')) {
			const projectId = values.at(-1);
			const index = PROJECTS.findIndex((projectRow) => projectRow.id === projectId);
			if (index >= 0) PROJECTS.splice(index, 1);
			for (let cardIndex = CARDS.length - 1; cardIndex >= 0; cardIndex -= 1) {
				if (CARDS[cardIndex].delete_source_id === projectId) CARDS.splice(cardIndex, 1);
			}
			for (const taskRow of TASKS) {
				if (taskRow.project_id === projectId) taskRow.project_id = null;
			}
		}
		if (query.includes('DELETE FROM projects WHERE deleted_at IS NOT NULL')) {
			const deletedIds = new Set(PROJECTS.filter((row) => row.deleted_at !== null).map((row) => row.id));
			for (const taskRow of TASKS) {
				if (deletedIds.has(taskRow.project_id)) taskRow.project_id = null;
			}
			for (let cardIndex = CARDS.length - 1; cardIndex >= 0; cardIndex -= 1) {
				if (CARDS[cardIndex].deleted_at !== null) CARDS.splice(cardIndex, 1);
			}
			for (let index = PROJECTS.length - 1; index >= 0; index -= 1) {
				if (deletedIds.has(PROJECTS[index].id)) PROJECTS.splice(index, 1);
			}
		}
		return [1, lastInsertId];
	}

	function recordSqlWrite(query, values) {
		persistDatabase();
		window.__E2E_SQL_WRITES__.push({ query, values });
		window.dispatchEvent(new CustomEvent('cuepad:e2e-sql-write', { detail: { query, values } }));
	}

	function selectSql(query, values = []) {
		const rows = structuredClone(routeSelect(query, values));
		const entity = query.includes('FROM projects')
			? 'projects'
			: query.includes('FROM cards') || query.includes('cards.*')
				? 'cards'
				: query.includes('FROM tasks')
					? 'tasks'
					: null;
		if (
			entity &&
			query.includes('WHERE id = $1') &&
			window.__E2E_HOLD_ENTITY_SELECT__ === entity
		) {
			window.__E2E_HOLD_ENTITY_SELECT__ = null;
			return new Promise((resolve) => {
				window.__E2E_RELEASE_ENTITY_SELECT__ = () => {
					window.__E2E_RELEASE_ENTITY_SELECT__ = null;
					resolve(rows);
				};
				window.dispatchEvent(new CustomEvent('cuepad:e2e-select-held', { detail: entity }));
			});
		}
		return Promise.resolve(rows);
	}

	let callbackId = 0;

	window.__E2E_CLIPBOARD__ = '';
	window.__E2E_SQL_WRITES__ = [];
	window.__E2E_DISPATCH__ = '';
	window.__E2E_DISPATCH_CALLS__ = 0;
	window.__E2E_DISPATCH_TARGET__ = null;
	window.__E2E_DISPATCH_ERROR__ = '';
	window.__E2E_HOLD_ENTITY_SELECT__ = null;
	window.__E2E_RELEASE_ENTITY_SELECT__ = null;
	window.__E2E_DISPATCH_TARGETS__ = [
		{ bundleId: 'com.apple.Terminal', name: 'Terminal' },
		{ bundleId: 'com.microsoft.VSCode', name: 'Visual Studio Code' },
		{ bundleId: 'dev.zed.Zed', name: 'Zed' }
	];

	window.cuepad = {
		app: { version: () => Promise.resolve('0.0.0-e2e') },
		events: { onOpenSettings: () => () => undefined },
		sql: {
			execute(query, values = []) {
				const [rowsAffected, lastInsertId] = routeExecute(query, values);
				recordSqlWrite(query, values);
				return Promise.resolve({ rowsAffected, lastInsertId });
			},
			select: selectSql,
			executeBatch(statements) {
				for (const statement of statements) {
					routeExecute(statement.query, statement.bindValues ?? []);
				}
				recordSqlWrite(
					statements.map((statement) => statement.query).join(';\n'),
					statements.flatMap((statement) => statement.bindValues ?? [])
				);
				return Promise.resolve();
			}
		}
	};

	window.__TAURI_INTERNALS__ = {
		invoke(cmd, args = {}) {
			switch (cmd) {
				case 'plugin:global-shortcut|is_registered':
					return Promise.resolve(false);
				case 'plugin:app|version':
					return Promise.resolve('0.0.0-e2e');
				case 'plugin:clipboard-manager|write_text': {
					const text = args?.data ?? args?.text ?? '';
					window.__E2E_CLIPBOARD__ = text;
					return new Promise((resolve) => {
						resolve(null);
						// 下一 task 才报告完成：确保 copyPrompt 的 await/finally 已执行完
						setTimeout(
							() =>
								window.dispatchEvent(
									new CustomEvent('cuepad:e2e-clipboard-complete', { detail: text })
								),
							0
						);
					});
				}
				case 'dispatch_target':
					return Promise.resolve({ bundleId: 'com.apple.Terminal', name: 'Terminal' });
				case 'dispatch_targets':
					return Promise.resolve(window.__E2E_DISPATCH_TARGETS__);
				case 'dispatch_text':
					if (window.__E2E_DISPATCH_ERROR__) {
						return Promise.reject(window.__E2E_DISPATCH_ERROR__);
					}
					if (
						args.bundleId &&
						!window.__E2E_DISPATCH_TARGETS__.some((target) => target.bundleId === args.bundleId)
					) {
						return Promise.reject('DISPATCH_TARGET_UNAVAILABLE');
					}
					return new Promise((resolve) =>
						setTimeout(() => {
							window.__E2E_DISPATCH__ = args.text;
							window.__E2E_DISPATCH_CALLS__ += 1;
							window.__E2E_DISPATCH_TARGET__ = args.bundleId ?? null;
							const detail = {
								text: args.text,
								bundleId: args.bundleId ?? null,
								calls: window.__E2E_DISPATCH_CALLS__
							};
							resolve(null);
							// 下一 task 才报告完成：确保 dispatchPrompt 的 await/finally 已执行完
							setTimeout(
								() =>
									window.dispatchEvent(
										new CustomEvent('cuepad:e2e-dispatch-complete', { detail })
									),
								0
							);
						}, window.__E2E_DISPATCH_DELAY__ ?? 0)
					);
				default:
					// listen/unlisten/register/path 等：成功空响应即可
					return Promise.resolve(null);
			}
		},
		transformCallback(callback) {
			const id = ++callbackId;
			window[`_${id}`] = callback;
			return id;
		},
		unregisterCallback(id) {
			delete window[`_${id}`];
		}
	};
})();
