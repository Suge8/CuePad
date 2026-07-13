<script lang="ts">
	import clean from '$lib/assets/ip-clean.png';
	import empty from '$lib/assets/ip-empty.png';
	import error from '$lib/assets/ip-error.png';
	import hello from '$lib/assets/ip-hello.png';
	import search from '$lib/assets/ip-search.png';
	import trash from '$lib/assets/ip-trash.png';
	import welcome from '$lib/assets/ip-welcome.png';

	const POSES = { clean, empty, error, hello, search, trash, welcome } as const;

	let {
		pose,
		size = 120
	}: {
		pose: keyof typeof POSES;
		size?: number;
	} = $props();
</script>

<img
	class="mascot"
	src={POSES[pose]}
	alt=""
	aria-hidden="true"
	draggable="false"
	style:height="{size}px"
/>

<style>
	.mascot {
		width: auto;
		user-select: none;
		pointer-events: none;
		animation: fx-mascot-float 5.6s var(--ease-standard) infinite alternate;
	}

	@media (prefers-reduced-motion: reduce) {
		.mascot {
			animation: none;
		}
	}
</style>
