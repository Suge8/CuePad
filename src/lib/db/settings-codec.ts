import type { SettingValue } from './types';

export function encodeSettingValue(value: SettingValue): string {
	const encoded = JSON.stringify(value);
	if (encoded === undefined) throw new Error('Setting value must be JSON serializable.');
	return encoded;
}

export function decodeSettingValue(key: string, value: string): SettingValue {
	try {
		return JSON.parse(value) as SettingValue;
	} catch (cause) {
		throw new Error(`Setting "${key}" is not valid JSON.`, { cause });
	}
}
