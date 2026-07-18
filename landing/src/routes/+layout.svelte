<script lang="ts">
	import '../app.css';
	import { onMount } from 'svelte';
	import { i18n, t, applyBootLang } from '$lib/i18n.svelte';

	let { children } = $props();

	onMount(() => {
		applyBootLang();
	});

	/* Language side effects: <html> attrs, title, meta description */
	$effect(() => {
		const lang = i18n.lang;
		document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
		document.documentElement.setAttribute('data-lang', lang);
		document.title = t('meta.title');
		document.querySelector('meta[name="description"]')?.setAttribute('content', t('meta.desc'));
	});
</script>

{@render children()}
