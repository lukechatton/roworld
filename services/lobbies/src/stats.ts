// Humans per public match (the goal: 50 humans per server): summaries of the match starts the
// store saw (a lobby record going open -> started), for GET /stats (JSON) and GET /stats.html.
import type { MatchStart } from "./store";

export const BANDS: [number, number, string][] = [
	[1, 1, "1"],
	[2, 4, "2-4"],
	[5, 9, "5-9"],
	[10, 19, "10-19"],
	[20, 29, "20-29"],
	[30, 39, "30-39"],
	[40, 49, "40-49"],
	[50, 1000, "50+"],
];

export interface Summary {
	matches: number;
	avg: number;
	median: number;
	p90: number;
	max: number;
	humans: number; // humans who started a public match
}

export function summarize(list: MatchStart[]): Summary {
	if (list.length === 0) return { matches: 0, avg: 0, median: 0, p90: 0, max: 0, humans: 0 };
	const h = list.map((m) => m.humans).sort((a, b) => a - b);
	const sum = h.reduce((a, b) => a + b, 0);
	const at = (q: number): number => h[Math.min(h.length - 1, Math.floor(q * (h.length - 1) + 0.5))];
	return { matches: h.length, avg: Math.round((sum / h.length) * 10) / 10, median: at(0.5), p90: at(0.9), max: h[h.length - 1], humans: sum };
}

export function band(n: number): string {
	for (const [lo, hi, name] of BANDS) if (n >= lo && n <= hi) return name;
	return "0";
}

export interface Stats {
	generated: number;
	lastHour: Summary;
	last24h: Summary;
	last7d: Summary;
	last30d: Summary;
	best: MatchStart | null;
	bands24h: Record<string, number>;
	hourly: ({ t: number } & Summary)[]; // last 48 h, oldest first
	daily: ({ t: number } & Summary)[]; // last 30 days (UTC), oldest first
	recent: MatchStart[]; // the last 20, newest first
	now?: { waiting: number; playing: number; running: number; open: { map: string; players: number; max: number; startsIn: number }[] };
}

function buckets(list: MatchStart[], now: number, size: number, count: number): ({ t: number } & Summary)[] {
	const end = Math.floor(now / size) * size + size;
	const out: ({ t: number } & Summary)[] = [];
	for (let i = count - 1; i >= 0; i--) {
		const t0 = end - (i + 1) * size;
		out.push({ t: t0, ...summarize(list.filter((m) => m.t >= t0 && m.t < t0 + size)) });
	}
	return out;
}

export function buildStats(starts: MatchStart[], now: number): Stats {
	const since = (s: number): MatchStart[] => starts.filter((m) => m.t >= now - s);
	const day = since(24 * 3600);
	const bands24h: Record<string, number> = {};
	for (const [, , name] of BANDS) bands24h[name] = 0;
	for (const m of day) {
		const b = band(m.humans);
		if (b in bands24h) bands24h[b]++;
	}
	let best: MatchStart | null = null;
	for (const m of starts) if (!best || m.humans > best.humans) best = m;
	return {
		generated: now,
		lastHour: summarize(since(3600)),
		last24h: summarize(day),
		last7d: summarize(since(7 * 24 * 3600)),
		last30d: summarize(since(30 * 24 * 3600)),
		best,
		bands24h,
		hourly: buckets(starts, now, 3600, 48),
		daily: buckets(starts, now, 24 * 3600, 30),
		recent: starts.slice(-20).reverse(),
	};
}
