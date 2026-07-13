export const VARIABLE_PATTERN = /\{\{([^{}\n]+)\}\}/g;

/** 提取变量名，重复变量只保留第一次出现的位置。 */
export function parseVariables(text: string): string[] {
	const variables: string[] = [];
	const seen = new Set<string>();
	for (const match of text.matchAll(VARIABLE_PATTERN)) {
		const name = match[1];
		if (seen.has(name)) continue;
		seen.add(name);
		variables.push(name);
	}
	return variables;
}

/** 替换已填写的变量值；未提供或留空的变量保留原始占位符（空串不是有效填充）。 */
export function fillVariables(text: string, values: Record<string, string>): string {
	return text.replace(VARIABLE_PATTERN, (placeholder, name: string) =>
		Object.hasOwn(values, name) && values[name] !== '' ? values[name] : placeholder
	);
}
