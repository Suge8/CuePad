<script lang="ts">
	// 品牌四角星：logo 语言的最小图形单元，用于点缀与成功反馈
	let { size = 16 }: { size?: number } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
	<path
		d="M12 0C13.1 7.4 16.6 10.9 24 12 16.6 13.1 13.1 16.6 12 24 10.9 16.6 7.4 13.1 0 12 7.4 10.9 10.9 7.4 12 0Z"
	/>
</svg>
