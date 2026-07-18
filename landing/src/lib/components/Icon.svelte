<script lang="ts">
	import PATHS from '$lib/icons';

	let { name, class: cls = 'ic' }: { name: keyof typeof PATHS; class?: string } = $props();
</script>

<svg class={cls} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
	{@html PATHS[name]}
</svg>
