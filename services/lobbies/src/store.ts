// The lobby store: what MemoryStoreService held for the public lobbies (docs/lobby-service.md), in
// memory on one process. Lobby records (opaque JSON, sorted by start time), PrivateServerId -> lobby
// id, and short leases. Every write stamps the row with a new version from one counter, so a
// compare-and-set (cas) can't be fooled by a row that was removed and written again (no ABA).
// The game keeps all the lobby rules (LobbyRules.luau); this only stores, expires and orders.

export interface Row {
	value: Record<string, unknown>;
	sort: number;
	version: number;
	exp: number; // unix s
}

export interface Limits {
	lobbies: number; // rows at most (a flood of bad writes can't grow memory without bound)
	psids: number;
	locks: number;
	maxTtl: number; // s
	listMax: number; // rows returned by list
}

/** Longest one owner keeps a lock by renewing it; then the next asker gets it and that owner sits out
 * LOCK_REST_S. A hub that always had lobbies to make kept the "scheduler" lease for good, and during a
 * rollout that was a hub of the old version: v93's new kind (World's queue) was never made while the
 * old servers bled off (2026-10-19). */
export const LOCK_MAX_HOLD_S = 20;
export const LOCK_REST_S = 6;

export const DEFAULT_LIMITS: Limits = { lobbies: 2000, psids: 2000, locks: 200, maxTtl: 3 * 3600, listMax: 300 };

export type CasResult = { ok: true; version: number } | { ok: false; err: "conflict"; value: Record<string, unknown> | false; version: number } | { ok: false; err: "full" };

/** The kinds of public match: free-for-all, a team game, and World's own free-for-all (always open,
 * 2026-10-19). A record's kind is its `mode`; a record without one is a free-for-all. */
export type Kind = "ffa" | "team" | "world";
export function kindOf(v: Record<string, unknown>): Kind {
	return v.mode === "team" ? "team" : v.mode === "world" ? "world" : "ffa";
}

/** Seats asked for in one step (take): `n` seats for `uids` in the soonest open lobby of `mode` (or of
 * any of `modes`, when given: a free-for-all join takes World's lobbies too, 2026-10-19) with room that
 * starts after `closeBefore` (joins close before the start) and no later than `startBefore` (a record
 * written with a wrong clock is skipped); `id`: only that lobby. The thresholds come from the game
 * (LobbyRules): the service only compares. */
export interface TakeSpec {
	mode: Kind;
	modes?: Kind[];
	n: number;
	uids: string[];
	at: number;
	closeBefore: number;
	startBefore: number;
	id?: string;
}

/** Seat-ledger entries a record keeps at most (a 30-seat lobby's are well under the 4 KB record cap). */
export const MAX_SEATS = 60;

function ledger(v: Record<string, unknown>): Record<string, number> {
	const s = v.seats;
	// (Roblox's JSONEncode writes an empty table as [])
	if (!s || typeof s !== "object" || Array.isArray(s)) return {};
	const out: Record<string, number> = {};
	for (const [k, t] of Object.entries(s as Record<string, unknown>)) if (typeof t === "number") out[k] = t;
	return out;
}

/** A lobby record's player cap: `max`, or `slots` for a team game (LobbyStore.encode). */
export function sizeOf(v: Record<string, unknown>): number {
	return typeof v.max === "number" ? v.max : typeof v.slots === "number" ? v.slots : 0;
}

/** A public match that started: when, with how many humans, out of how many slots. */
export interface MatchStart {
	t: number; // unix s
	humans: number;
	max: number;
	map: string;
}

export interface Snapshot {
	seq: number;
	lobbies: [string, Row][];
	psids: [string, { id: string; exp: number }][];
	locks: [string, { owner: string; exp: number; since?: number }][];
	counters: Record<string, number>;
}

/** A lobby record without its seat ledger (`seats`): what a hub's list needs (LobbyStore.list). */
function withoutSeats(v: Record<string, unknown>): Record<string, unknown> {
	if (!("seats" in v)) return v;
	const { seats: _seats, ...rest } = v;
	return rest;
}

export class LobbyStore {
	readonly lobbies = new Map<string, Row>();
	readonly psids = new Map<string, { id: string; exp: number }>();
	readonly locks = new Map<string, { owner: string; exp: number; since?: number }>();
	/** name -> the owner whose turn just ended (LOCK_MAX_HOLD_S), and until when it sits out */
	private readonly lockRests = new Map<string, { owner: string; until: number }>();
	dirty = false;
	private seq = 0;
	readonly counters: Record<string, number> = { puts: 0, casOk: 0, casConflicts: 0, removes: 0, locksGranted: 0, locksRefused: 0, expired: 0, takes: 0, takeMisses: 0, seatsReleased: 0 };
	/** Public matches started (a record going open -> started: MatchHost.start writes the humans who
	 * started it), oldest first, the last STARTS_KEEP_S. */
	readonly starts: MatchStart[] = [];
	static readonly STARTS_KEEP_S = 30 * 24 * 3600;
	static readonly STARTS_MAX = 200_000;

	/** Called for every match start (main.ts appends it to starts.jsonl). */
	onStart: ((m: MatchStart) => void) | null = null;
	/** Called after every lobby write (the live stats page is told; the server throttles). */
	onChange: (() => void) | null = null;

	private changed(): void {
		this.dirty = true;
		this.gen++;
		if (this.onChange) this.onChange();
	}

	/** Bumped whenever the lobby rows change (a write, a lease running out, a restore): what
	 * listJson's cache is checked against. */
	private gen = 0;
	private readonly listCache = new Map<string, { gen: number; at: number; json: string }>();
	/** listJson's answer is reused for at most this long (s) with no change, so a row whose lease ran
	 * out without a write to say so still drops out promptly. */
	static readonly LIST_CACHE_S = 0.5;

	constructor(
		private readonly now: () => number,
		readonly limits: Limits = DEFAULT_LIMITS,
	) {}

	/** Starts read back from starts.jsonl at boot (oldest first). */
	loadStarts(list: MatchStart[]): void {
		const cutoff = this.now() - LobbyStore.STARTS_KEEP_S;
		for (const m of list) if (m && typeof m.t === "number" && typeof m.humans === "number" && m.t >= cutoff) this.starts.push(m);
		this.starts.sort((a, b) => a.t - b.t);
		if (this.starts.length > LobbyStore.STARTS_MAX) this.starts.splice(0, this.starts.length - LobbyStore.STARTS_MAX);
	}

	private ttl(ttl: number): number {
		return Math.max(1, Math.min(this.limits.maxTtl, ttl));
	}

	private live(id: string): Row | undefined {
		const r = this.lobbies.get(id);
		if (r === undefined) return undefined;
		if (r.exp <= this.now()) {
			this.lobbies.delete(id);
			this.counters.expired++;
			this.dirty = true;
			this.gen++;
			return undefined;
		}
		return r;
	}

	private sorted(): [string, Row][] {
		const rows: [string, Row][] = [];
		for (const id of [...this.lobbies.keys()]) {
			const r = this.live(id);
			if (r) rows.push([id, r]);
		}
		rows.sort((a, b) => a[1].sort - b[1].sort || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
		return rows;
	}

	/** Live rows, earliest start first (ties: id), at most limits.listMax. `live`: every row not
	 * started, and only the `live` started ones that started last (a hub needs the open lobbies and a
	 * few running matches, not every match of the last 15 minutes: 2026-10-11, 250 rows to each of
	 * ~530 hubs every 3 s). `summary`: each row without its seat ledger (`seats`, up to 50 user ids with
	 * the time of each seat: 79% of the list's bytes on 2026-10-24, 137 KB a reply to each of ~1,100
	 * hubs every 3 s); a hub's list reads none of it (a match server reads its own record's, by get). */
	list(live?: number, summary = false): { value: Record<string, unknown>; version: number }[] {
		let rows = this.sorted();
		if (live !== undefined) {
			let started = 0;
			for (const [, r] of rows) if (r.value.status === "started") started++;
			let skip = Math.max(0, started - live);
			rows = rows.filter(([, r]) => r.value.status !== "started" || skip-- <= 0);
		}
		let keep = rows;
		if (rows.length > this.limits.listMax) {
			// both ends (as the MemoryStore version did): the oldest (running matches) and the newest
			// (the open lobbies), so many live matches never push the open lobbies off the list
			const half = Math.floor(this.limits.listMax / 2);
			keep = rows.slice(0, half).concat(rows.slice(rows.length - (this.limits.listMax - half)));
		}
		return keep.map(([, r]) => ({ value: summary ? withoutSeats(r.value) : r.value, version: r.version }));
	}

	/** list(live) as JSON, built once per change of the rows and reused until the next one (or
	 * LIST_CACHE_S). Every hub asks for the list every few seconds, two thirds of all requests, and
	 * building and serializing up to listMax rows for each was most of the service's CPU (2026-10-14,
	 * at 11,172 players online: 56-63% of its one core at 256 requests a second). */
	listJson(live?: number, summary = false): string {
		const key = `${live === undefined ? -1 : live}:${summary ? 1 : 0}`;
		const t = this.now();
		const c = this.listCache.get(key);
		if (c !== undefined && c.gen === this.gen && t - c.at < LobbyStore.LIST_CACHE_S) {
			this.counters.listReused = (this.counters.listReused ?? 0) + 1;
			return c.json;
		}
		const json = JSON.stringify(this.list(live, summary));
		// (after the build: a lease that ran out while listing has already bumped gen)
		this.listCache.set(key, { gen: this.gen, at: t, json });
		this.counters.listBuilt = (this.counters.listBuilt ?? 0) + 1;
		return json;
	}

	get(id: string): { value: Record<string, unknown> | false; version: number } {
		const r = this.live(id);
		return r ? { value: r.value, version: r.version } : { value: false, version: 0 };
	}

	/** A new open lobby never starts more than this far out (s; 0 = off). The game's own rule is
	 * LobbyRules.LOBBY_OPEN_S (90 s, v47); this also holds older game servers to it (90 s at most,
	 * 2026-09-28). */
	maxLeadS = 90;

	put(id: string, value: Record<string, unknown>, sort: number, ttl: number): number | null {
		if (!this.live(id) && this.lobbies.size >= this.limits.lobbies) return null;
		if (this.maxLeadS > 0 && !this.live(id) && value.status === "open" && typeof value.starts === "number" && value.starts > this.now() + this.maxLeadS) {
			value = { ...value, starts: this.now() + this.maxLeadS };
			sort = value.starts as number;
			this.counters.clamped = (this.counters.clamped ?? 0) + 1;
		}
		const version = ++this.seq;
		this.lobbies.set(id, { value, sort, version, exp: this.now() + this.ttl(ttl) });
		this.counters.puts++;
		this.changed();
		return version;
	}

	/** Write only if the row is still at `expect` (0 = absent); on a conflict the reply carries the
	 * current row, so the caller retries without another read. */
	cas(id: string, expect: number, value: Record<string, unknown>, sort: number, ttl: number): CasResult {
		const cur = this.live(id);
		const curVersion = cur ? cur.version : 0;
		if (curVersion !== expect) {
			this.counters.casConflicts++;
			return { ok: false, err: "conflict", value: cur ? cur.value : false, version: curVersion };
		}
		if (!cur && this.lobbies.size >= this.limits.lobbies) return { ok: false, err: "full" };
		const version = ++this.seq;
		this.lobbies.set(id, { value, sort, version, exp: this.now() + this.ttl(ttl) });
		this.counters.casOk++;
		if (cur && cur.value.status !== "started" && value.status === "started") this.noteStart(value);
		this.changed();
		return { ok: true, version };
	}

	/** Seats in one step (TakeSpec): the soonest lobby that fits gets `n` more players and the takers in
	 * its seat ledger (`seats`: user id -> when), at a new version. One request instead of a get and
	 * compare-and-sets that conflicted ~2.5 times per write on the one lobby everyone joined
	 * (2026-10-11). `value: false` when no lobby has room. */
	take(spec: TakeSpec): { value: Record<string, unknown> | false; version: number; id?: string } {
		const kinds = spec.modes && spec.modes.length > 0 ? spec.modes : [spec.mode];
		for (const [id, r] of this.sorted()) {
			if (spec.id !== undefined && id !== spec.id) continue;
			const v = r.value;
			if (v.status !== "open" || !kinds.includes(kindOf(v))) continue;
			const starts = typeof v.starts === "number" ? v.starts : 0;
			if (starts <= spec.closeBefore || starts > spec.startBefore) continue;
			const players = Math.max(0, Math.floor(Number(v.players) || 0));
			if (players + spec.n > sizeOf(v)) continue;
			const seats = ledger(v);
			for (const u of spec.uids) if (Object.keys(seats).length < MAX_SEATS) seats[u] = spec.at;
			r.value = { ...v, players: players + spec.n, seats };
			r.version = ++this.seq;
			this.counters.takes++;
			this.changed();
			return { value: r.value, version: r.version, id };
		}
		this.counters.takeMisses++;
		return { value: false, version: 0 };
	}

	/** Gives back the seats of `uids` in an open lobby (a teleport that failed, a player who left the
	 * waiting room or never arrived): only seats in its ledger, so a seat is never given back twice
	 * (the hub and the match server may both try). */
	release(id: string, uids: string[]): { value: Record<string, unknown> | false; version: number; released: number } {
		const r = this.live(id);
		if (!r) return { value: false, version: 0, released: 0 };
		const v = r.value;
		const seats = ledger(v);
		let n = 0;
		for (const u of uids) {
			if (seats[u] !== undefined) {
				delete seats[u];
				n++;
			}
		}
		if (n === 0 || v.status !== "open") return { value: v, version: r.version, released: 0 };
		r.value = { ...v, players: Math.max(0, Math.floor(Number(v.players) || 0) - n), seats };
		r.version = ++this.seq;
		this.counters.seatsReleased += n;
		this.changed();
		return { value: r.value, version: r.version, released: n };
	}

	private noteStart(v: Record<string, unknown>): void {
		const humans = Math.max(0, Math.min(1000, Math.floor(Number(v.players) || 0)));
		const max = Math.max(0, Math.min(1000, Math.floor(sizeOf(v))));
		const map = typeof v.map === "string" ? v.map.slice(0, 40) : "?";
		const m = { t: this.now(), humans, max, map };
		this.starts.push(m);
		if (this.onStart) this.onStart(m);
		this.counters.matchesStarted = (this.counters.matchesStarted ?? 0) + 1;
		const cutoff = this.now() - LobbyStore.STARTS_KEEP_S;
		let drop = 0;
		while (drop < this.starts.length && (this.starts[drop].t < cutoff || this.starts.length - drop > LobbyStore.STARTS_MAX)) drop++;
		if (drop > 0) this.starts.splice(0, drop);
	}

	remove(id: string): void {
		if (this.lobbies.delete(id)) {
			this.counters.removes++;
			this.changed();
		}
	}

	/** A short lease: true when `owner` holds `name` now (granted or renewed). The service's clock
	 * decides expiry, so game servers whose clocks disagree can't both hold it. Renewals last
	 * LOCK_MAX_HOLD_S at most: then the lease is free for others and its owner sits out LOCK_REST_S. */
	lock(name: string, owner: string, ttl: number): boolean {
		const t = this.now();
		const cur = this.locks.get(name);
		if (cur && cur.owner !== owner && cur.exp > t) {
			this.counters.locksRefused++;
			return false;
		}
		const rest = this.lockRests.get(name);
		if (rest && rest.owner === owner && rest.until > t) {
			this.counters.locksRefused++;
			return false;
		}
		const held = cur && cur.owner === owner && cur.exp > t;
		const since = held ? (cur.since ?? t) : t;
		if (held && t - since >= LOCK_MAX_HOLD_S) {
			// its turn is over: the next asker's
			this.locks.delete(name);
			this.lockRests.set(name, { owner, until: t + LOCK_REST_S });
			this.counters.locksRefused++;
			this.counters.locksRotated = (this.counters.locksRotated ?? 0) + 1;
			return false;
		}
		if (!cur && this.locks.size >= this.limits.locks) this.sweep();
		if (!this.locks.has(name) && this.locks.size >= this.limits.locks) return false;
		this.locks.set(name, { owner, exp: t + Math.max(1, Math.min(300, ttl)), since });
		this.counters.locksGranted++;
		return true;
	}

	bindPsid(psid: string, id: string, ttl: number): boolean {
		if (!this.psids.has(psid) && this.psids.size >= this.limits.psids) {
			this.sweep();
			if (this.psids.size >= this.limits.psids) return false;
		}
		this.psids.set(psid, { id, exp: this.now() + this.ttl(ttl) });
		this.dirty = true;
		return true;
	}

	/** The lobby record of a reserved server (by its PrivateServerId). */
	lookupPsid(psid: string): { value: Record<string, unknown> | false; version: number } {
		const p = this.psids.get(psid);
		if (!p || p.exp <= this.now()) {
			if (p) this.psids.delete(psid);
			return { value: false, version: 0 };
		}
		return this.get(p.id);
	}

	sweep(): void {
		const t = this.now();
		for (const [id, r] of this.lobbies) if (r.exp <= t) this.live(id);
		for (const [k, p] of this.psids) if (p.exp <= t) this.psids.delete(k);
		for (const [k, l] of this.locks) if (l.exp <= t) this.locks.delete(k);
		for (const [k, r] of this.lockRests) if (r.until <= t) this.lockRests.delete(k);
	}

	/** What is happening now, for the stats page (maps and counts only): open lobbies and the
	 * humans in them, running public matches (a beat within liveStale s) and their humans. */
	liveNow(liveStale = 100): { waiting: number; playing: number; running: number; open: { map: string; players: number; max: number; startsIn: number }[] } {
		const t = this.now();
		let waiting = 0;
		let playing = 0;
		let running = 0;
		const open: { map: string; players: number; max: number; startsIn: number }[] = [];
		for (const r of this.lobbies.values()) {
			if (r.exp <= t) continue;
			const v = r.value;
			const players = Math.max(0, Math.floor(Number(v.players) || 0));
			const max = Math.max(0, Math.floor(sizeOf(v)));
			const starts = Number(v.starts) || 0;
			if (v.status === "open" && starts > t) {
				waiting += Math.min(players, max || players);
				open.push({ map: typeof v.map === "string" ? v.map.slice(0, 40) : "?", players: Math.min(players, max || players), max, startsIn: Math.round(starts - t) });
			} else if (v.status === "started" && typeof v.beat === "number" && t - v.beat < liveStale) {
				running++;
				playing += players;
			}
		}
		open.sort((a, b) => a.startsIn - b.startsIn);
		return { waiting, playing, running, open: open.slice(0, 10) };
	}

	counts(): Record<string, number> {
		let open = 0;
		let started = 0;
		const t = this.now();
		for (const r of this.lobbies.values()) {
			if (r.exp <= t) continue;
			if (r.value.status === "open") open++;
			else started++;
		}
		return { lobbies: open + started, open, started, psids: this.psids.size, locks: this.locks.size };
	}

	snapshot(): Snapshot {
		this.sweep();
		return { seq: this.seq, lobbies: [...this.lobbies], psids: [...this.psids], locks: [...this.locks], counters: { ...this.counters } };
	}

	restore(s: Snapshot): number {
		this.seq = Math.max(this.seq, Number(s.seq) || 0);
		for (const [k, v] of s.lobbies ?? []) this.lobbies.set(k, v);
		for (const [k, v] of s.psids ?? []) this.psids.set(k, v);
		for (const [k, v] of s.locks ?? []) this.locks.set(k, v);
		for (const [k, v] of Object.entries(s.counters ?? {})) if (typeof v === "number") this.counters[k] = v;
		this.gen++;
		this.sweep();
		return this.lobbies.size;
	}
}
