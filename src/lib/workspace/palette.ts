import BookOpenIcon from 'lucide-svelte/icons/book-open';
import BracesIcon from 'lucide-svelte/icons/braces';
import CameraIcon from 'lucide-svelte/icons/camera';
import CloudIcon from 'lucide-svelte/icons/cloud';
import CoffeeIcon from 'lucide-svelte/icons/coffee';
import FlagIcon from 'lucide-svelte/icons/flag';
import FolderIcon from 'lucide-svelte/icons/folder';
import GlobeIcon from 'lucide-svelte/icons/globe';
import HeartIcon from 'lucide-svelte/icons/heart';
import ImageIcon from 'lucide-svelte/icons/image';
import LayersIcon from 'lucide-svelte/icons/layers';
import LightbulbIcon from 'lucide-svelte/icons/lightbulb';
import MusicIcon from 'lucide-svelte/icons/music';
import PaletteIcon from 'lucide-svelte/icons/palette';
import PenLineIcon from 'lucide-svelte/icons/pen-line';
import RocketIcon from 'lucide-svelte/icons/rocket';
import SparklesIcon from 'lucide-svelte/icons/sparkles';
import StarIcon from 'lucide-svelte/icons/star';
import TargetIcon from 'lucide-svelte/icons/target';
import TerminalIcon from 'lucide-svelte/icons/terminal';
import ZapIcon from 'lucide-svelte/icons/zap';

export interface PaletteColor {
	name: string;
	value: string;
	/** 色块上图标/文字的前景色，手工标定省去运行时亮度计算 */
	foreground: string;
}

export const PROJECT_COLORS: PaletteColor[] = [
	{ name: 'Pink', value: '#e2679c', foreground: '#fff7fa' },
	{ name: 'Red', value: '#dd5f52', foreground: '#fff8f6' },
	{ name: 'Orange', value: '#e78a3a', foreground: '#fff9f2' },
	{ name: 'Yellow', value: '#dfae35', foreground: '#2e2510' },
	{ name: 'Green', value: '#55ab6e', foreground: '#f3fbf5' },
	{ name: 'Teal', value: '#3fa8a0', foreground: '#f0fbfa' },
	{ name: 'Blue', value: '#4f8ce8', foreground: '#f4f8ff' },
	{ name: 'Indigo', value: '#7a76e3', foreground: '#f6f6ff' },
	{ name: 'Purple', value: '#a86ad6', foreground: '#fbf5ff' },
	{ name: 'Sage', value: '#9fb0a1', foreground: '#1e2a21' }
];

export function paletteForeground(color: string): string {
	return PROJECT_COLORS.find((item) => item.value === color)?.foreground ?? '#1e2a21';
}

export type ProjectIcon = typeof PenLineIcon;

const ICONS: Record<string, ProjectIcon> = {
	pen: PenLineIcon,
	sparkles: SparklesIcon,
	braces: BracesIcon,
	book: BookOpenIcon,
	terminal: TerminalIcon,
	bulb: LightbulbIcon,
	rocket: RocketIcon,
	star: StarIcon,
	heart: HeartIcon,
	flag: FlagIcon,
	folder: FolderIcon,
	image: ImageIcon,
	camera: CameraIcon,
	music: MusicIcon,
	globe: GlobeIcon,
	cloud: CloudIcon,
	palette: PaletteIcon,
	zap: ZapIcon,
	coffee: CoffeeIcon,
	target: TargetIcon,
	layers: LayersIcon
};

export const PROJECT_ICON_KEYS = Object.keys(ICONS);

export function projectIcon(key: string | null): ProjectIcon | null {
	return key ? (ICONS[key] ?? null) : null;
}
