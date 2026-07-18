<script lang="ts">
	import { onMount } from 'svelte';
	import { t } from '$lib/i18n.svelte';
	import { observeReveals } from '$lib/reveal';
	import Nav from '$lib/components/Nav.svelte';
	import Hero from '$lib/components/Hero.svelte';
	import GhostBand from '$lib/components/GhostBand.svelte';
	import Drench from '$lib/components/Drench.svelte';
	import Steps from '$lib/components/Steps.svelte';
	import Features from '$lib/components/Features.svelte';
	import DeskBand from '$lib/components/DeskBand.svelte';
	import Cinema from '$lib/components/Cinema.svelte';
	import Download from '$lib/components/Download.svelte';
	import Footer from '$lib/components/Footer.svelte';

	onMount(() => observeReveals());
</script>

<a class="skip" href="#main">{t('skip')}</a>
<div class="grain" aria-hidden="true"></div>

<Nav />

<main id="main">
	<Hero />
	<GhostBand />
	<Drench />
	<Steps />
	<Features />
	<DeskBand />
	<Cinema />
	<Download />
</main>

<Footer />
