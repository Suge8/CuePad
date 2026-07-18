<script lang="ts">
	import { onMount } from 'svelte';
	import { i18n, setLang, t, LINKS } from '$lib/i18n.svelte';
	import Icon from './Icon.svelte';

	let head: HTMLElement;
	let bar: HTMLElement;

	onMount(() => {
		let ticking = false;
		const onScroll = () => {
			if (ticking) return;
			ticking = true;
			requestAnimationFrame(() => {
				head.classList.toggle('scrolled', window.scrollY > 10);
				const max = document.documentElement.scrollHeight - window.innerHeight;
				bar.style.setProperty('--sp', (max > 0 ? window.scrollY / max : 0).toFixed(3));
				ticking = false;
			});
		};
		window.addEventListener('scroll', onScroll, { passive: true });
		onScroll();
		return () => window.removeEventListener('scroll', onScroll);
	});
</script>

<div class="progress" bind:this={bar} aria-hidden="true"></div>
<header class="site-head" bind:this={head}>
	<nav class="nav" aria-label="Main">
		<a class="brand" href="#top"><span class="brandmark" aria-hidden="true"></span>CuePad</a>
		<div class="nav-links">
			<a href="#dispatch">{t('nav.dispatch')}</a>
			<a href="#how">{t('nav.how')}</a>
			<a href="#features">{t('nav.features')}</a>
			<a href="#download">{t('nav.download')}</a>
		</div>
		<div class="nav-tools">
			<div class="lang" role="group" aria-label="Language / 语言">
				<button type="button" aria-pressed={i18n.lang === 'en'} onclick={() => setLang('en')}>EN</button>
				<button type="button" aria-pressed={i18n.lang === 'zh'} onclick={() => setLang('zh')}>中文</button>
			</div>
			<a class="gh-link" href={LINKS.repo} target="_blank" rel="noopener" aria-label="CuePad on GitHub">
				<Icon name="github" />
			</a>
			<a class="nav-cta" href={LINKS.download} download>
				<Icon name="download" /><span>{t('nav.cta')}</span>
			</a>
		</div>
	</nav>
</header>
