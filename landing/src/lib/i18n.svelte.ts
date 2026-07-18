/* CuePad Landing — bilingual copy single source of truth (Svelte 5 runes) */

export type Lang = 'en' | 'zh';

export const LINKS = {
	repo: 'https://github.com/Suge8/CuePad',
	/** Stable asset name — see electron-builder.yml artifactName */
	download:
		'https://github.com/Suge8/CuePad/releases/latest/download/CuePad-mac-arm64.zip'
} as const;

export const i18n = $state({ lang: 'en' as Lang });

const DICT: Record<Lang, Record<string, string>> = {
	en: {
		'meta.title': 'CuePad — Write your prompt, dispatch in one tap',
		'meta.desc':
			'CuePad is a calm, paper-like scratchpad for coding agents. Write comfortably, autosave every keystroke, and land your prompt in the terminal or editor in one tap. 100% local on macOS.',
		skip: 'Skip to content',
		'nav.dispatch': 'Dispatch',
		'nav.how': 'How it works',
		'nav.features': 'Features',
		'nav.download': 'Download',
		'nav.cta': 'Download',
		'hero.t1': 'Write your prompt,',
		'hero.t2': 'dispatch in ',
		'hero.t3': 'one tap',
		'hero.t4': '.',
		'hero.sub': 'A calm, paper-like scratchpad beside your coding agents — write, autosave, dispatch.',
		'hero.cta1': 'Download for macOS',
		'hero.cta2': 'Star on GitHub',
		'sim.title': 'Refactor module',
		'sim.pin': 'Terminal',
		'sim.send': 'Dispatch',
		'sim.aria': 'Animation: a prompt typed in CuePad flies into the terminal',
		'sim.typed': 'Refactor {{module}} into {{target}}. Keep every test green.',
		'ghost.line': 'WRITE · DISPATCH · REPEAT',
		'drench.h': 'One tap. It lands where you were typing.',
		'drench.p':
			'Leave your cursor in the target input and summon CuePad. Hit dispatch — the text lands right where you were typing. Pin your favorite target, and let auto-send press Enter for you.',
		'drench.meta': 'Terminal · iTerm · Zed · VS Code — pin a target, auto-send presses ⏎',
		'drench.local':
			'100% local — every card lives in one SQLite file on your Mac. No account. No cloud. No telemetry.',
		'drench.video': 'Recording: dispatching a prompt from CuePad into a terminal',
		'how.h': 'From idea to prompt in three moves',
		'how.1.h': 'Write like on paper',
		'how.1.p':
			'Full-screen cards with light styling for headings, lists and code blocks. Plain text in, plain text out — every keystroke autosaves.',
		'how.2.h': 'Summon from anywhere',
		'how.2.p':
			'CuePad lives in the tray and hides instead of closing. One global shortcut brings it back, right over your work.',
		'how.3.h': 'Dispatch, cursor intact',
		'how.3.p':
			'Send the whole card, or split it into blocks and dispatch any single one — numbered if you like.',
		'feat.h': 'Everything a draft needs',
		'f1.h': 'A full-screen card that gets out of the way',
		'f1.p':
			'Immersive editing with gentle styling for <code>## headings</code>, <code>- lists</code>, code blocks and <code>{{variables}}</code>. Split a draft into blocks with <code>Shift + Enter</code>, then copy or dispatch the whole card or any single block.',
		'f1.t1': 'Plain text in, plain text out',
		'f1.t2': 'Per-block copy & dispatch',
		'f1.t3': 'Optional block numbering',
		'f1.img1': 'Immersive full-screen card editing in CuePad',
		'f1.img2': 'A draft split into dispatchable blocks',
		'f2.h': 'Fill the blanks at send time',
		'f2.p':
			'Draft with <code>{{variables}}</code>; CuePad asks for the values right before you copy or dispatch — and each card remembers your last answers.',
		'f2.t1': 'Reusable prompt templates',
		'f2.t2': 'Per-card memory',
		'f2.img': 'Filling variable values before dispatch',
		'f3.h': 'Find anything in a keystroke',
		'f3.p':
			'<span class="kbd">⌘ F</span> searches projects, cards and tags from anywhere. Enter jumps straight to the card.',
		'f3.img': 'Global search across projects, cards and tags',
		'f4.h': 'Loose ends, parked',
		'f4.p': 'A horizontal project bar, global favorites, floating to-dos — and a trash that forgives.',
		'f4.img': 'Floating tasks beside the card board',
		'desk.line': 'A quiet desk for loud ideas.',
		'cinema.h': 'Calm after dark',
		'cinema.p': 'Light, dark, or follow the system — the paper stays easy on your eyes.',
		'cinema.img': 'CuePad card board in dark theme',
		'dl.h': 'Download. Open. Write.',
		'dl.p':
			'CuePad is free and open source under Apache-2.0. One click gets the latest Apple Silicon build.',
		'dl.cta1': 'Download for macOS',
		'dl.cta2': 'Star on GitHub',
		'dl.note':
			'Ad-hoc signed, not notarized — on first launch, right-click the app and choose Open.',
		'dl.source': 'Prefer building from source? Three commands on GitHub →',
		'dl.req1': 'macOS · Apple Silicon',
		'dl.req2': 'Apache-2.0',
		'dl.req3': '100% local',
		'foot.made': 'Made locally, on a Mac.'
	},
	zh: {
		'meta.title': 'CuePad — 写好提示词，一键投送',
		'meta.desc':
			'CuePad 是一块安静的纸感草稿板，伴在你的 coding agent 旁边：舒服地写、逐键自动保存，一键把提示词投送回终端或编辑器。完全本地，开源免费。',
		skip: '跳到正文',
		'nav.dispatch': '一键投送',
		'nav.how': '怎么用',
		'nav.features': '功能',
		'nav.download': '下载',
		'nav.cta': '下载',
		'hero.t1': '写好提示词，',
		'hero.t2': '',
		'hero.t3': '一键投送',
		'hero.t4': '。',
		'hero.sub': '伴在 coding agent 旁边的纸感草稿板。写好，一键送回终端。',
		'hero.cta1': '下载 macOS 版',
		'hero.cta2': '去 GitHub 加星',
		'sim.title': '重构模块',
		'sim.pin': 'Terminal',
		'sim.send': '投送',
		'sim.aria': '动画：在 CuePad 输入的提示词飞入终端',
		'sim.typed': '把 {{模块路径}} 重构为 {{目标形态}}，保持所有测试通过。',
		'ghost.line': '写好 · 投送 · 再来',
		'drench.h': '点一下，落回你刚才打字的地方。',
		'drench.p':
			'光标留在目标输入框，唤出 CuePad 点投送——文本直达刚才的位置。可固定常用目标，「自动发送」还会替你补按回车。',
		'drench.meta': 'Terminal · iTerm · Zed · VS Code —— 固定常用目标，自动发送替你补按 ⏎',
		'drench.local':
			'完全本地——所有卡片保存在你 Mac 上的一个 SQLite 文件里。无账号、无云端、无遥测。',
		'drench.video': '录屏：提示词从 CuePad 投送到终端',
		'how.h': '三步，从想法到提示词',
		'how.1.h': '像纸上一样写',
		'how.1.p': '全屏卡片，标题、列表、代码块有轻量排版。纯文本进、纯文本出，逐键自动保存。',
		'how.2.h': '随叫随到',
		'how.2.p': '常驻托盘、关闭即隐藏。一个全局快捷键，把它唤回到你的工作上方。',
		'how.3.h': '投送，光标不动',
		'how.3.p': '整卡发送，或 Shift + Enter 切成块，任意一块单独投送——可带编号。',
		'feat.h': '草稿该有的，都有',
		'f1.h': '全屏卡片，不挡路',
		'f1.p':
			'沉浸编辑，<code>## 标题</code>、<code>- 列表</code>、代码块和 <code>{{变量}}</code> 有轻量视觉增强。<code>Shift + Enter</code> 把草稿切成块，整卡或任意一块单独复制、投送。',
		'f1.t1': '纯文本进、纯文本出',
		'f1.t2': '按块复制 / 投送',
		'f1.t3': '可选块编号',
		'f1.img1': 'CuePad 全屏沉浸编辑卡片',
		'f1.img2': '草稿切成可单独投送的块',
		'f2.h': '发送前才填空',
		'f2.p': '用 <code>{{变量}}</code> 写模板，复制或投送前集中填写；每张卡记住你上次的答案。',
		'f2.t1': '可复用的提示词模板',
		'f2.t2': '按卡记住上次填写',
		'f2.img': '投送前集中填写变量',
		'f3.h': '一键即搜',
		'f3.p': '<span class="kbd">⌘ F</span> 随处搜索项目、卡片与标签，回车直达那张卡。',
		'f3.img': '全局搜索项目、卡片与标签',
		'f4.h': '杂事，先停在这',
		'f4.p': '横向项目栏、全局收藏、悬浮待办，还有一个可以反悔的回收站。',
		'f4.img': '卡片墙旁的悬浮任务',
		'desk.line': '安静的桌面，装得下喧闹的想法。',
		'cinema.h': '入夜，依然安静',
		'cinema.p': '浅色、深色或跟随系统——纸感始终柔和。',
		'cinema.img': '深色主题下的 CuePad 卡片墙',
		'dl.h': '下载，打开，开写。',
		'dl.p': 'CuePad 免费开源（Apache-2.0）。一键下载最新 Apple Silicon 构建。',
		'dl.cta1': '下载 macOS 版',
		'dl.cta2': '去 GitHub 加星',
		'dl.note': 'ad-hoc 签名、未公证——首次启动请右键选择「打开」。',
		'dl.source': '想从源码构建？GitHub 上三条命令 →',
		'dl.req1': 'macOS · Apple Silicon',
		'dl.req2': 'Apache-2.0',
		'dl.req3': '完全本地',
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
