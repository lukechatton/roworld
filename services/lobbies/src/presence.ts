// Who is doing what right now, across the game (the stats page: how many people are playing solos,
// 2026-09-28). Hubs send their counts with every lobby list (every 3 s): players on the server,
// in an unfinished solo match by difficulty, and the rest (title screen). Public-match players come
// from the lobby records (LobbyStore.liveNow). A sample every minute keeps a 30-day history.

export interface HubCounts {
	players: number;
	solo: number;
	soloEasy: number;
	soloMedium: number;
	soloHard: number;
	title: number;
}

export interface Sample {
	t: number; // unix s
	solo: number;
	title: number;
	waiting: number; // humans in open lobbies (public, not started)
	playing: number; // humans in running public matches
	hubs: number; // hub servers reporting
}

const ZERO: HubCounts = { players: 0, solo: 0, soloEasy: 0, soloMedium: 0, soloHard: 0, title: 0 };

export class Presence {
	private readonly hubs = new Map<string, { at: number; c: HubCounts }>();
	readonly samples: Sample[] = [];
	onSample: ((s: Sample) => void) | null = null;
	static readonly STALE_S = 20;
	static readonly KEEP_S = 30 * 24 * 3600;

	constructor(private readonly now: () => number) {}

	/** A hub's latest counts (validated by the route). */
	report(jobId: string, c: HubCounts): void {
		this.hubs.set(jobId, { at: this.now(), c });
	}

	/** Sums over hubs heard from in the last STALE_S. */
	totals(): HubCounts & { hubs: number } {
		const cutoff = this.now() - Presence.STALE_S;
		const t = { ...ZERO, hubs: 0 };
		for (const [k, h] of this.hubs) {
			if (h.at < cutoff) {
				this.hubs.delete(k);
				continue;
			}
			t.hubs++;
			t.players += h.c.players;
			t.solo += h.c.solo;
			t.soloEasy += h.c.soloEasy;
			t.soloMedium += h.c.soloMedium;
			t.soloHard += h.c.soloHard;
			t.title += h.c.title;
		}
		return t;
	}

	/** One history point (main.ts: every minute). */
	sample(waiting: number, playing: number): Sample {
		const t = this.totals();
		const s: Sample = { t: Math.floor(this.now()), solo: t.solo, title: t.title, waiting, playing, hubs: t.hubs };
		this.samples.push(s);
		const cutoff = this.now() - Presence.KEEP_S;
		let drop = 0;
		while (drop < this.samples.length && this.samples[drop].t < cutoff) drop++;
		if (drop > 0) this.samples.splice(0, drop);
		if (this.onSample) this.onSample(s);
		return s;
	}

	loadSamples(list: Sample[]): void {
		const cutoff = this.now() - Presence.KEEP_S;
		for (const s of list) if (s && typeof s.t === "number" && s.t >= cutoff) this.samples.push(s);
		this.samples.sort((a, b) => a.t - b.t);
	}

	/** The last `hours` of samples averaged into `buckets` points (the page's chart). */
	series(hours: number, buckets: number): { t: number; solo: number; title: number; waiting: number; playing: number }[] {
		const end = this.now();
		const size = (hours * 3600) / buckets;
		const out: { t: number; solo: number; title: number; waiting: number; playing: number }[] = [];
		let i = 0;
		const start = end - hours * 3600;
		while (i < this.samples.length && this.samples[i].t < start) i++;
		for (let b = 0; b < buckets; b++) {
			const t0 = start + b * size;
			let n = 0;
			const acc = { solo: 0, title: 0, waiting: 0, playing: 0 };
			// (the last bucket also takes a sample made this very second)
			while (i < this.samples.length && (this.samples[i].t < t0 + size || b === buckets - 1)) {
				const s = this.samples[i++];
				acc.solo += s.solo;
				acc.title += s.title;
				acc.waiting += s.waiting;
				acc.playing += s.playing;
				n++;
			}
			if (n > 0) out.push({ t: Math.round(t0), solo: Math.round(acc.solo / n), title: Math.round(acc.title / n), waiting: Math.round(acc.waiting / n), playing: Math.round(acc.playing / n) });
		}
		return out;
	}
}
