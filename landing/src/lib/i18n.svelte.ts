/* CuePad Landing — bilingual copy single source of truth (Svelte 5 runes) */

export type Lang = 'en' | 'zh';

export const LINKS = {
	repo: 'https://github.com/Suge8/CuePad',
	/** Stable asset name; the download artifact is produced by `xc.sh release mac` */
	download:
		'https://github.com/Suge8/CuePad/releases/latest/download/CuePad-mac-arm64.zip'
} as const;

export const i18n = $state({ lang: 'en' as Lang });

const DICT: Record<Lang, Record<string, string>> = {
	en: {
		'meta.title': 'CuePad — Say it once. Cue keeps your agents moving.',
		'meta.desc':
			'A calm notebook that runs your coding agents. Jot it down; Cue hands it to Claude Code, Codex, Pi, OpenCode, Grok Build or DeepSeek Harness, keeps them moving, and only asks you what really needs you. Native on Mac, iPhone and iPad. Local-first, free and open source.',
		skip: 'Skip to content',
		'nav.cue': 'Cue',
		'nav.how': 'How it works',
		'nav.features': 'Features',
		'nav.download': 'Download',
		'nav.cta': 'Download',
		'hero.t1': 'Say it once.',
		'hero.t2': 'Cue keeps your ',
		'hero.t3': 'agents moving',
		'hero.t4': '.',
		'hero.sub':
			'A calm notebook that runs your coding agents. Jot it down; Cue hands it to Claude Code, Codex, Pi, OpenCode, Grok Build or DeepSeek Harness and only asks you what really needs you.',
		'hero.cta1': 'Download for Mac',
		'hero.cta2': 'Star on GitHub',
		'hero.img': 'The CuePad task board: to do, advancing, waiting on you, done',
		'ghost.line': 'SAY IT · CUE RUNS IT · DONE',
		'drench.h': 'Say what you want. Cue takes it from there.',
		'drench.p':
			'Type it on the Mac or say it from your phone. Cue turns it into tasks, starts and names agent sessions, answers their routine questions, checks their evidence and signs off finished work.',
		'drench.meta': 'Claude\u00a0Code · Codex · Pi · OpenCode · Grok\u00a0Build · DeepSeek\u00a0Harness — ⌥\u00a0⇧\u00a0Space from anywhere',
		'drench.local':
			'Local-first — everything lives in a SQLite library on your device and syncs through your own private iCloud. No account, no server, no telemetry.',
		'drench.video': 'Recording: tell Cue what you want; it starts an agent session and reports back',
		'how.h': 'From one sentence to finished work',
		'how.1.h': 'Say it',
		'how.1.p':
			'Tell Cue what you want from anywhere, or write a task and press Start. Ideas that aren’t ready yet wait as plain Markdown.',
		'how.2.h': 'Cue runs it',
		'how.2.p':
			'Cue picks the agent, starts the session, answers routine questions and checks the evidence before calling it done.',
		'how.3.h': 'You sign off',
		'how.3.p':
			'Only what can’t be undone — pushing, releasing, deleting — waits on you. One number, one tap each.',
		'how.3.k': 'Waiting 3',
		'feat.h': 'Built for handing work off',
		'f1.h': 'Cue reports back with proof',
		'f1.p':
			'What it did folds into one line; screenshots and test runs come back as evidence. When something truly needs you, it asks once, with what you need to decide.',
		'f1.t1': 'Starts and names agent sessions',
		'f1.t2': 'Checks evidence before calling it done',
		'f1.t3': 'Asks only before what can’t be undone',
		'f1.img': 'Cue reports back with evidence and asks whether to push',
		'f2.h': 'Agents show you their work',
		'f2.p':
			'Screenshots, pages, PDFs and recordings land in the conversation, each captioned with what to look at. Annotate any part of a reply and it goes out with your next message.',
		'f2.t1': 'Every preview says what to check',
		'f2.t2': 'Annotate any passage',
		'f2.img': 'An agent session with a delivered page and two annotations in the reply box',
		'f3.h': 'Your phone is the remote',
		'f3.p':
			'Answer an agent’s question or permission request from anywhere, and check its work before it ships. Native on iPhone and iPad.',
		'f3.img': 'An agent’s work, previewed on the iPhone',
		'f4.h': 'Ideas first',
		'f4.p':
			'Plain Markdown with inline images and <code>{{variables}}</code>. When it’s time to act, drag an idea onto a task; every send is logged and can be resent.',
		'f4.img': 'A project page: tasks on top, ideas below',
		'desk.line': 'A quiet desk for busy agents.',
		'cinema.h': 'Every agent on one board',
		'cinema.p':
			'To do, advancing, waiting on you, done — with each session’s live state beside it. Light, dark, or follow the system.',
		'cinema.img': 'The CuePad task board in dark theme',
		'dl.h': 'Download. Open. Say it.',
		'dl.p':
			'CuePad is free and open source under Apache-2.0. On first launch it finds the agents on your Mac and connects the ones you pick.',
		'dl.cta1': 'Download for Mac',
		'dl.cta2': 'Star on GitHub',
		'dl.note':
			'Notarized and updates itself. The interface is in Simplified Chinese for now; iCloud sync and the iPhone and iPad apps need your own Apple developer account.',
		'dl.source': 'Prefer to build it yourself? Clone and open in Xcode →',
		'dl.req1': 'macOS 26+ · Apple Silicon',
		'dl.req2': 'Apache-2.0',
		'dl.req3': 'Local-first',
		'foot.made': 'Made locally, on a Mac.'
	},
	zh: {
		'meta.title': 'CuePad — 说一句，Cue 替你盯着所有 Agent',
		'meta.desc':
			'一本替你指挥 coding agent 的安静笔记本。记下来，Cue 交给 Claude Code、Codex、Pi、OpenCode、Grok Build 或 DeepSeek Harness，盯着它们推进，只把真正要你拍板的事拿来问你。Mac、iPhone、iPad 原生，本地优先，开源免费。',
		skip: '跳到正文',
		'nav.cue': 'Cue',
		'nav.how': '怎么用',
		'nav.features': '功能',
		'nav.download': '下载',
		'nav.cta': '下载',
		'hero.t1': '说一句，',
		'hero.t2': 'Cue 替你',
		'hero.t3': '盯着 Agent',
		'hero.t4': '。',
		'hero.sub':
			'一本替你指挥 coding agent 的安静笔记本。记下来，Cue 交给 Claude Code、Codex、Pi、OpenCode、Grok Build 或 DeepSeek Harness，只把真正要你拍板的事拿来问你。',
		'hero.cta1': '下载 Mac 版',
		'hero.cta2': '去 GitHub 加星',
		'hero.img': 'CuePad 的任务看板：待办、推进中、等你、已完成',
		'ghost.line': '说一句 · Cue 推进 · 做完',
		'drench.h': '你开口，Cue 接手。',
		'drench.p':
			'在 Mac 上打字，或在手机上说出你要什么。Cue 把它变成任务，开好并命名 Agent 会话，回答常规提问，核对证据，自己判定做完。',
		'drench.meta': 'Claude\u00a0Code · Codex · Pi · OpenCode · Grok\u00a0Build · DeepSeek\u00a0Harness —— 随处按 ⌥\u00a0⇧\u00a0Space 叫 Cue',
		'drench.local':
			'本地优先——全部存在设备上的 SQLite 库里，经你自己的 iCloud 私有数据库同步。无需账号，没有服务器，没有遥测。',
		'drench.video': '录屏：告诉 Cue 要做什么，它开好 Agent 会话、回来报告结果',
		'how.h': '从一句话到做完',
		'how.1.h': '说一句',
		'how.1.p': '在哪都能告诉 Cue 你要什么，或写一条任务点“开始”。还没想好的先记成灵感，纯 Markdown。',
		'how.2.h': 'Cue 去推进',
		'how.2.p': 'Cue 挑好 Agent、开好会话，回答常规提问，核对过证据才算做完。',
		'how.3.h': '你来拍板',
		'how.3.p': '只有推送、发布、删除这类收不回的事才等你：汇成一个数字，点一下答一件。',
		'how.3.k': '等你 3',
		'feat.h': '为放手交出去而做',
		'f1.h': 'Cue 带着证据回来交差',
		'f1.p':
			'做过的事折成一行，截图和测试结果作为证据一起带回。真要你拍板时只问一次，判断要用的都摆在眼前。',
		'f1.t1': '开好并命名 Agent 会话',
		'f1.t2': '核对过证据才算做完',
		'f1.t3': '只在收不回的事之前问你',
		'f1.img': 'Cue 带着证据交差，并问要不要推送',
		'f2.h': 'Agent 把成果摆给你看',
		'f2.p':
			'截图、网页、PDF、录屏直接发进对话，每个都写明看哪里。回答里任意一段都能批注，随下一句一起发出。',
		'f2.t1': '每份成果写明看哪里',
		'f2.t2': '任意一段都能批注',
		'f2.img': 'Agent 会话：发来的页面，回复框里带着两条批注',
		'f3.h': '手机就是遥控器',
		'f3.p': '在哪都能回答 Agent 的提问和权限请求，上线前先在手机上验收。iPhone、iPad 原生。',
		'f3.img': '在 iPhone 上看 Agent 发来的成果',
		'f4.h': '灵感优先',
		'f4.p':
			'纯 Markdown，带内联图片与 <code>{{变量}}</code>。要动手时把灵感拖进任务，每次发送都留快照、可重发。',
		'f4.img': '项目页：上面是任务，下面是灵感',
		'desk.line': '安静的桌面，忙碌的 Agent。',
		'cinema.h': '所有 Agent，一块看板',
		'cinema.p': '待办、推进中、等你、已完成四列，旁边是每个会话的实时状态。浅色、深色或跟随系统。',
		'cinema.img': '深色主题下的 CuePad 任务看板',
		'dl.h': '下载，打开，说一句。',
		'dl.p': 'CuePad 免费开源（Apache-2.0）。首次打开时找出这台 Mac 上的 Agent，勾上哪家就接上哪家。',
		'dl.cta1': '下载 Mac 版',
		'dl.cta2': '去 GitHub 加星',
		'dl.note': '已公证，自动更新。iCloud 同步与 iPhone、iPad 版目前需要你自己的 Apple 开发者账号。',
		'dl.source': '想自己编译？克隆后用 Xcode 打开 →',
		'dl.req1': 'macOS 26+ · Apple Silicon',
		'dl.req2': 'Apache-2.0',
		'dl.req3': '本地优先',
		'foot.made': '在一台 Mac 上本地制造。'
	}
};

export function t(key: string): string {
	return DICT[i18n.lang][key] ?? DICT.en[key] ?? key;
}

/* Read the pre-paint boot pick; applied after hydration so server/client
 * markup match (an {@html} block would otherwise keep stale SSR content) */
let bootLang: Lang | null = null;
if (typeof document !== 'undefined') {
	const boot = document.documentElement.getAttribute('data-lang');
	bootLang = boot === 'zh' ? 'zh' : 'en';
}
export function applyBootLang() {
	if (bootLang) i18n.lang = bootLang;
}

export function setLang(next: Lang) {
	const apply = () => {
		i18n.lang = next;
	};
	try {
		localStorage.setItem('cuepad-lang', next);
	} catch (e) {}
	const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
	if (document.startViewTransition && !reduced) {
		document.startViewTransition(apply);
	} else {
		apply();
	}
}
