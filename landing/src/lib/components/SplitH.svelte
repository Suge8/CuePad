<script lang="ts">
	/* Split heading: each CJK character (with the punctuation that follows it) and each
	   Latin word is one unit, so zh lines never break inside "Cue" or before "，" */
	let { text, class: cls = '' }: { text: string; class?: string } = $props();
	let el: HTMLElement;

	$effect(() => {
		const current = text;
		if (!el) return;
		el.textContent = '';
		const units = current.match(/[\u4e00-\u9fff][\u3000-\u303f\uff00-\uffef]*|[^\s\u4e00-\u9fff]+|\s+/g) ?? [];
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
