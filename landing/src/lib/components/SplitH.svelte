<script lang="ts">
	/* Split heading: zh per character, en per word; re-splits when its text changes */
	let { text, class: cls = '' }: { text: string; class?: string } = $props();
	let el: HTMLElement;

	$effect(() => {
		const current = text;
		if (!el) return;
		el.textContent = '';
		const units = /[\u4e00-\u9fff]/.test(current) ? Array.from(current) : current.split(/(\s+)/);
		let i = 0;
		for (const unit of units) {
			if (/^\s+$/.test(unit)) {
				el.appendChild(document.createTextNode(unit));
				continue;
			}
			const span = document.createElement('span');
			span.className = 'ch';
			span.style.setProperty('--i', String(i++));
			span.textContent = unit;
			el.appendChild(span);
		}
	});
</script>

<h2 class="split {cls}" bind:this={el}>{text}</h2>
