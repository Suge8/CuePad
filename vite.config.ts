import path from 'node:path';
import tailwindcss from '@tailwindcss/vite';
import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

const e2eArtifacts = process.env.CUEPAD_E2E_DIR;
const electronRenderer = process.env.CUEPAD_ELECTRON === '1';
// 测试构建用独立目录：常驻 dev 的 sync、普通 build 与测试 build 并发重写同一目录会互相破坏
const kitOutDir = process.env.SVELTEKIT_OUT_DIR;
const kitBuildDir = process.env.SVELTEKIT_BUILD_DIR ?? 'build';

export default defineConfig({
	// Electron G1 仍加载 baseline renderer；只在 Electron dev/test 替换其唯一启动期 Tauri 壳入口。
	resolve: {
		alias: electronRenderer
			? { '@tauri-apps/api/event': path.resolve(import.meta.dirname, 'electron/event.ts') }
			: {}
	},
	// 并发 E2E 的 Vite 实例不能共享 node_modules/.vite：dep 预构建写竞态会触发 full-reload
	cacheDir: e2eArtifacts ? `${e2eArtifacts}/vite-cache` : undefined,
	server: {
		watch: {
			// 非源码写入会触发 full-reload；build 还会重写整个 .svelte-kit，E2E 时一并排除
			ignored: [
				'**/.flow/**',
				'**/build/**',
				'**/build-wdio/**',
				'**/e2e/**',
				'**/design/**',
				'**/docs/**',
				'**/.svelte-kit-wdio/**',
				...(e2eArtifacts ? ['**/.svelte-kit/**'] : [])
			]
		}
	},
	plugins: [
		tailwindcss(),
		sveltekit({
			...(kitOutDir ? { outDir: kitOutDir } : {}),
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) => filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			adapter: adapter({
				pages: kitBuildDir,
				assets: kitBuildDir,
				fallback: '200.html'
			})
		})
	]
});
