// How the game servers keep up (2026-11-01). The Creator Dashboard's server frame rate P10 had fallen
// to 1-4 fps at night (21:00-08:00 UTC, from ~56 in early October) while the median stayed at 60, and
// nothing said which servers those were. Every live server now sends a summary of each minute
// (POST /v1/perf, from the game's ServerPerf.luau): its frame rate and slow frames, its match's Sim
// step times and what it runs. Kept here: each server's latest report (/health and /stats.json: the
// counts by frame rate and the slowest servers now), a log line for each slow report, and a sample a
// minute in perf.jsonl (30 days): how many servers reported and how many were slow, by role.
import { int, Invalid, num, obj, optStr } from "./validate";

export interface PerfReport {
	role: "hub" | "match";
	fps: number;
	slowShare: number; // the share of the minute spent in frames of 100 ms or more
	slowFrames: number;
	worstMs: number;
	steps: number;
	stepMsAvg: number;
	stepMsP99: number;
	stepMsMax: number;
	encodeMsAvg: number;
	catchupFrames: number;
	budgetStops: number;
	stage: string | null;
	humans: number;
	players: number;
	map: string | null;
	mode: string | null;
	max: number | null;
	minute: number | null;
	attacks: number | null;
	memMb: number;
	ageMin: number;
	version: number;
	// the minute's joins (server/Handoff): with the records the last server handed on, without them
	// (its entry didn't come), and not from one of our teleports; records handed on; Stars that could
	// not be paid after every retry (2026-11-03)
	handoffHits: number;
	handoffMisses: number;
	handoffNone: number;
	handoffSent: number;
	starsLost: number;
	starsLostAmount: number;
}

const WORD_RE = /^[0-9A-Za-z_.:-]{1,32}$/;

/** A report from a request body (untrusted: every field checked). */
export function parseReport(v: unknown): PerfReport {
	const o = obj(v, "perf");
	const n = (k: string, hi: number): number => num(o[k] ?? 0, `perf.${k}`, 0, hi);
	const opt = (k: string, hi: number): number | null => (o[k] === undefined || o[k] === null ? null : num(o[k], `perf.${k}`, 0, hi));
	const role = o.role === "match" ? "match" : o.role === "hub" ? "hub" : null;
	if (role === null) throw new Invalid("perf.role: hub or match expected");
	return {
		role,
		fps: n("fps", 1000),
		slowShare: n("slow_share", 1),
		slowFrames: int(o.slow_frames ?? 0, "perf.slow_frames", 0, 1e6),
		worstMs: n("worst_ms", 3.6e6),
		steps: int(o.steps ?? 0, "perf.steps", 0, 1e6),
		stepMsAvg: n("step_ms_avg", 1e6),
		stepMsP99: n("step_ms_p99", 1e6),
		stepMsMax: n("step_ms_max", 1e6),
		encodeMsAvg: n("encode_ms_avg", 1e6),
		catchupFrames: int(o.catchup_frames ?? 0, "perf.catchup_frames", 0, 1e6),
		budgetStops: int(o.budget_stops ?? 0, "perf.budget_stops", 0, 1e6),
		stage: optStr(o.stage, "perf.stage", 32, WORD_RE),
		humans: n("humans", 1000),
		players: n("players", 1000),
		map: optStr(o.map, "perf.map", 32, WORD_RE),
		mode: optStr(o.mode, "perf.mode", 32, WORD_RE),
		max: opt("max", 1000),
		minute: opt("minute", 1e5),
		attacks: opt("attacks", 1e6),
		memMb: n("mem_mb", 1e6),
		ageMin: n("age_min", 1e7),
		version: n("version", 1e7),
		handoffHits: int(o.handoff_hits ?? 0, "perf.handoff_hits", 0, 1e6),
		handoffMisses: int(o.handoff_misses ?? 0, "perf.handoff_misses", 0, 1e6),
		handoffNone: int(o.handoff_none ?? 0, "perf.handoff_none", 0, 1e6),
		handoffSent: int(o.handoff_sent ?? 0, "perf.handoff_sent", 0, 1e6),
		starsLost: int(o.stars_lost ?? 0, "perf.stars_lost", 0, 1e6),
		starsLostAmount: int(o.stars_lost_amount ?? 0, "perf.stars_lost_amount", 0, 1e9),
	};
}

/** Frame-rate bands for the counts (a report's fps over its minute). */
export const FPS_BANDS: [number, string][] = [
	[55, "55+"],
	[30, "30-55"],
	[10, "10-30"],
	[3, "3-10"],
	[0, "under 3"],
];

export function fpsBand(fps: number): string {
	for (const [lo, name] of FPS_BANDS) if (fps >= lo) return name;
	return "under 3";
}

export interface PerfSample {
	t: number; // unix s
	hubs: number;
	matches: number;
	slowHubs: number; // under SLOW_FPS
	slowMatches: number;
	// the counts below summed over the servers' latest minutes (absent in samples before 2026-11-03)
	handoff?: HandoffCounts;
	starsLost?: { payouts: number; stars: number };
}

export interface HandoffCounts {
	hits: number;
	misses: number;
	none: number;
	sent: number;
}

export class Perf {
	private readonly servers = new Map<string, { at: number; r: PerfReport }>();
	private readonly lastLog = new Map<string, number>();
	readonly samples: PerfSample[] = [];
	onSample: ((s: PerfSample) => void) | null = null;
	onSlow: ((jobId: string, r: PerfReport) => void) | null = null;
	/** Reports older than this are gone (a server reports every minute). */
	static readonly STALE_S = 150;
	/** A server under this frame rate over its minute is slow (logged, counted). */
	static readonly SLOW_FPS = 10;
	/** A slow server is logged at most this often. */
	static readonly LOG_EVERY_S = 300;
	static readonly KEEP_S = 30 * 24 * 3600;

	constructor(private readonly now: () => number) {}

	report(jobId: string, r: PerfReport): void {
		const t = this.now();
		this.servers.set(jobId, { at: t, r });
		if (r.fps < Perf.SLOW_FPS && this.onSlow) {
			const last = this.lastLog.get(jobId) ?? -Infinity;
			if (t - last >= Perf.LOG_EVERY_S) {
				this.lastLog.set(jobId, t);
				this.onSlow(jobId, r);
			}
		}
	}

	private live(): [string, PerfReport][] {
		const cutoff = this.now() - Perf.STALE_S;
		const out: [string, PerfReport][] = [];
		for (const [k, s] of this.servers) {
			if (s.at < cutoff) {
				this.servers.delete(k);
				this.lastLog.delete(k);
				continue;
			}
			out.push([k, s.r]);
		}
		return out;
	}

	/** Servers reporting now: counts by role and frame-rate band, and the slowest `top`. */
	summary(top = 15): {
		servers: number;
		byRole: Record<string, number>;
		bands: Record<string, Record<string, number>>;
		handoff: HandoffCounts;
		starsLost: { payouts: number; stars: number };
		slowest: (PerfReport & { job: string })[];
	} {
		const live = this.live();
		const byRole: Record<string, number> = { hub: 0, match: 0 };
		const bands: Record<string, Record<string, number>> = { hub: {}, match: {} };
		for (const role of ["hub", "match"]) for (const [, name] of FPS_BANDS) bands[role][name] = 0;
		for (const [, r] of live) {
			byRole[r.role]++;
			bands[r.role][fpsBand(r.fps)]++;
		}
		const { handoff, starsLost } = totals(live.map(([, r]) => r));
		live.sort((a, b) => a[1].fps - b[1].fps);
		const slowest = live.slice(0, top).map(([job, r]) => ({ job: job.slice(0, 8), ...r }));
		return { servers: live.length, byRole, bands, handoff, starsLost, slowest };
	}

	/** One history point (main.ts: every minute). */
	sample(): PerfSample {
		const live = this.live();
		const s: PerfSample = { t: Math.floor(this.now()), hubs: 0, matches: 0, slowHubs: 0, slowMatches: 0, ...totals(live.map(([, r]) => r)) };
		for (const [, r] of live) {
			const slow = r.fps < Perf.SLOW_FPS;
			if (r.role === "match") {
				s.matches++;
				if (slow) s.slowMatches++;
			} else {
				s.hubs++;
				if (slow) s.slowHubs++;
			}
		}
		this.samples.push(s);
		const cutoff = this.now() - Perf.KEEP_S;
		let drop = 0;
		while (drop < this.samples.length && this.samples[drop].t < cutoff) drop++;
		if (drop > 0) this.samples.splice(0, drop);
		if (this.onSample) this.onSample(s);
		return s;
	}

	loadSamples(list: PerfSample[]): void {
		const cutoff = this.now() - Perf.KEEP_S;
		for (const s of list) if (s && typeof s.t === "number" && s.t >= cutoff) this.samples.push(s);
		this.samples.sort((a, b) => a.t - b.t);
	}
}

/** The servers' latest minutes added up: hand-offs and lost Stars. */
function totals(reports: PerfReport[]): { handoff: HandoffCounts; starsLost: { payouts: number; stars: number } } {
	const handoff: HandoffCounts = { hits: 0, misses: 0, none: 0, sent: 0 };
	const starsLost = { payouts: 0, stars: 0 };
	for (const r of reports) {
		handoff.hits += r.handoffHits;
		handoff.misses += r.handoffMisses;
		handoff.none += r.handoffNone;
		handoff.sent += r.handoffSent;
		starsLost.payouts += r.starsLost;
		starsLost.stars += r.starsLostAmount;
	}
	return { handoff, starsLost };
}

/** A slow report as one log line. */
export function describe(jobId: string, r: PerfReport): string {
	const what = r.role === "match" ? `${r.mode ?? "?"} on ${r.map ?? "?"} (${r.humans}/${r.max ?? "?"} humans, minute ${r.minute ?? "?"}, ${r.attacks ?? "?"} attacks, stage ${r.stage ?? "?"})` : `hub (${r.players} players)`;
	return (
		`slow server ${jobId.slice(0, 8)}: ${r.fps} fps, ${Math.round(r.slowShare * 100)}% of the minute in slow frames, worst ${r.worstMs} ms | ` +
		`step avg ${r.stepMsAvg} p99 ${r.stepMsP99} max ${r.stepMsMax} ms, ${r.steps} steps, encode ${r.encodeMsAvg} ms, catch-up ${r.catchupFrames}, budget stops ${r.budgetStops} | ` +
		`${what}, ${r.memMb} MB, up ${r.ageMin} min, v${r.version}`
	);
}
