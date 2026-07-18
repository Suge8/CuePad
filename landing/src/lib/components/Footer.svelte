<script lang="ts">
	import { t, LINKS } from '$lib/i18n.svelte';
	import Icon from './Icon.svelte';

	const year = new Date().getFullYear();
</script>

<footer class="site-foot">
	<div class="foot-inner">
		<span class="foot-brand"><span class="brandmark" aria-hidden="true"></span>CuePad</span>
		<span>© {year} · Apache-2.0</span>
		<div class="foot-right">
			<span>{t('foot.made')}</span>
			<a class="gh-link" href={LINKS.repo} target="_blank" rel="noopener" aria-label="CuePad on GitHub">
				<Icon name="github" />
			</a>
		</div>
	</div>
</footer>
