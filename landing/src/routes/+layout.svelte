<script lang="ts">
	import '../app.css';
	import { onMount } from 'svelte';
	import { i18n, t, applyBootLang } from '$lib/i18n.svelte';

	let { children } = $props();

	onMount(() => {
		applyBootLang();
	});

	$effect(() => {
		const lang = i18n.lang;
		document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
		document.documentElement.setAttribute('data-lang', lang);
	});
</script>

<svelte:head>
	<title>{t('meta.title')}</title>
	<meta name="description" content={t('meta.desc')} />
</svelte:head>

{@render children()}
