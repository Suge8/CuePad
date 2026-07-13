import { describe, expect, test } from 'bun:test';
import { fillVariables, parseVariables } from '../src/lib/editor/variables';

describe('parseVariables', () => {
	test('无变量时返回空数组', () => {
		expect(parseVariables('纯文本')).toEqual([]);
	});

	test('重复变量去重并保留首次出现顺序', () => {
		expect(parseVariables('{{产品}} / {{语气}} / {{产品}}')).toEqual(['产品', '语气']);
	});
});

describe('fillVariables', () => {
	test('替换所有已填写变量，缺省值保留原样', () => {
		expect(fillVariables('{{产品}}：{{语气}}；再次 {{产品}}', { 产品: 'CuePad' })).toBe(
			'CuePad：{{语气}}；再次 CuePad'
		);
	});

	test('空字符串视为缺省：表单留空的变量保留占位符', () => {
		expect(fillVariables('{{甲}}/{{乙}}', { 甲: 'x', 乙: '' })).toBe('x/{{乙}}');
	});
});
