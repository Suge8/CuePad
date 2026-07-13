<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
	import { Compartment, EditorState } from '@codemirror/state';
	import { EditorView, keymap, placeholder as cmPlaceholder } from '@codemirror/view';
	import type { CardNumbering } from '$lib/db';
	import { blockKeymap } from './blocks';
	import { cueDecorations, numberingFacet } from './decorations';

	type Props = {
		value: string;
		onChange: (value: string) => void;
		placeholder?: string;
		numbering?: CardNumbering;
		onCopyBlock?: (text: string) => void;
	};

	let { value, onChange, placeholder = '', numbering = 'none', onCopyBlock }: Props = $props();

	const numberingCompartment = new Compartment();

	let host: HTMLDivElement;
	let view: EditorView | undefined;

	// 颜色/字体全部走 CSS 变量，随 data-theme 切换自动联动，无需监听主题
	const theme = EditorView.theme({
		'&': { fontSize: '0.92rem' },
		'&.cm-focused': { outline: 'none' },
		'.cm-scroller': {
			fontFamily: 'var(--font-sans)',
			lineHeight: '1.72',
			overflow: 'auto'
		},
		'.cm-content': {
			maxWidth: '42rem',
			margin: '0 auto',
			padding: '4.6rem 1.5rem 30vh',
			letterSpacing: '-0.012em',
			color: 'var(--color-text)',
			caretColor: 'var(--color-text-strong)'
		},
		'.cm-cursor': { borderLeftColor: 'var(--color-text-strong)' },
		'.cm-placeholder': { color: 'var(--color-text-soft)' }
	});

	onMount(() => {
		view = new EditorView({
			parent: host,
			state: EditorState.create({
				doc: value,
				extensions: [
					history(),
					blockKeymap((text) => onCopyBlock?.(text)),
					keymap.of([...defaultKeymap, ...historyKeymap]),
					numberingCompartment.of(numberingFacet.of(numbering)),
					EditorView.lineWrapping,
					cmPlaceholder(placeholder),
					theme,
					cueDecorations,
					EditorView.updateListener.of((update) => {
						if (update.docChanged) onChange(update.state.doc.toString());
					})
				]
			})
		});
		view.focus();
	});

	onDestroy(() => view?.destroy());

	// 外部替换内容（如恢复备份）；用户输入经 onChange 回流后此处相等、不重复 dispatch
	$effect(() => {
		if (view && value !== view.state.doc.toString()) {
			view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: value } });
		}
	});

	// 编号风格切换 → reconfigure facet，decorations 自行重建块头 badge
	$effect(() => {
		view?.dispatch({ effects: numberingCompartment.reconfigure(numberingFacet.of(numbering)) });
	});
</script>

<div class="editor-host" bind:this={host}></div>

<style>
	/* 高度由父层 flex 分配（FocusEditor 里 flex:1 + min-height:0，实测 clientHeight 为确定值），
	 * cm-editor 百分比参照这个确定高度，滚动发生在 cm-scroller */
	.editor-host {
		min-height: 0;
	}

	.editor-host :global(.cm-editor) {
		height: 100%;
	}
</style>
