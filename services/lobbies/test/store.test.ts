import { strict as assert } from "assert";
import { test } from "node:test";
import { LOCK_REST_S, LobbyStore } from "../src/store";

function clock(start = 1_000_000): { now: () => number; advance: (s: number) => void } {
	let t = start;
	return { now: () => t, advance: (s) => (t += s) };
}

test("put / get / list order by start time", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	s.put("b", { id: "b", starts: 200 }, 200, 60);
	s.put("a", { id: "a", starts: 100 }, 100, 60);
	assert.deepEqual(
		s.list().map((r) => r.value.id),
		["a", "b"],
	);
	assert.equal(s.get("a").value && (s.get("a").value as any).starts, 100);
	assert.deepEqual(s.get("zz"), { value: false, version: 0 });
});

test("rows expire at their ttl", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	s.put("a", { id: "a" }, 1, 10);
	c.advance(9.9);
	assert.ok(s.get("a").value);
	c.advance(0.2);
	assert.equal(s.get("a").value, false);
	assert.equal(s.list().length, 0);
});

test("cas: writes at the expected version, conflicts carry the current row", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	const v1 = s.put("a", { players: 0 }, 1, 60)!;
	const r1 = s.cas("a", v1, { players: 1 }, 1, 60);
	assert.ok(r1.ok);
	const stale = s.cas("a", v1, { players: 1 }, 1, 60);
	assert.equal(stale.ok, false);
	if (!stale.ok && stale.err === "conflict") {
		assert.deepEqual(stale.value, { players: 1 });
		const r2 = s.cas("a", stale.version, { players: 2 }, 1, 60);
		assert.ok(r2.ok);
	} else assert.fail("conflict expected");
	assert.deepEqual(s.get("a").value, { players: 2 });
});

test("cas on a removed and rewritten row fails (no ABA)", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	const v1 = s.put("a", { n: 1 }, 1, 60)!;
	s.remove("a");
	s.put("a", { n: 1 }, 1, 60);
	assert.equal(s.cas("a", v1, { n: 2 }, 1, 60).ok, false);
	assert.equal(s.cas("gone", 0, { n: 1 }, 1, 60).ok, true, "expect 0 = create when absent");
});

test("many writers racing on one lobby: every retried increment lands once", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	s.put("L", { players: 0 }, 1, 60);
	// 40 hubs read the same version, then retry with the conflict reply (like LobbyStore.http)
	const readers = Array.from({ length: 40 }, () => s.get("L"));
	let tries = 0;
	for (const r of readers) {
		let cur = r;
		for (;;) {
			tries++;
			const res = s.cas("L", cur.version, { players: ((cur.value as any).players as number) + 1 }, 1, 60);
			if (res.ok) break;
			if (res.err !== "conflict") assert.fail("unexpected");
			cur = { value: res.value, version: res.version };
		}
	}
	assert.equal((s.get("L").value as any).players, 40);
	assert.ok(tries >= 40);
});

test("locks: one owner at a time, renewable, free after expiry", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	assert.ok(s.lock("scheduler", "hubA", 10));
	assert.equal(s.lock("scheduler", "hubB", 10), false);
	assert.ok(s.lock("scheduler", "hubA", 10), "the owner renews");
	c.advance(10.1);
	assert.ok(s.lock("scheduler", "hubB", 10));
});

test("locks: an owner that keeps renewing gives the lock up after LOCK_MAX_HOLD_S, and sits out LOCK_REST_S", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	assert.ok(s.lock("scheduler", "old", 10));
	for (let i = 0; i < 6; i++) {
		c.advance(3);
		assert.ok(s.lock("scheduler", "old", 10), "renewing within its turn");
		assert.equal(s.lock("scheduler", "new", 10), false, "others wait meanwhile");
	}
	c.advance(3); // 21 s held
	assert.equal(s.lock("scheduler", "old", 10), false, "its turn is over");
	assert.equal(s.lock("scheduler", "old", 10), false, "and it sits out");
	assert.ok(s.lock("scheduler", "new", 10), "the next asker gets it at once");
	assert.equal(s.counters.locksRotated, 1);
	c.advance(LOCK_REST_S + 11);
	assert.ok(s.lock("scheduler", "old", 10), "after its rest and the new lease's end, the old owner may again");
	// a lone owner gets it back after its rest
	const s2 = new LobbyStore(c.now);
	assert.ok(s2.lock("scheduler", "solo", 10));
	for (let i = 0; i < 7; i++) {
		c.advance(3);
		s2.lock("scheduler", "solo", 10);
	}
	c.advance(LOCK_REST_S);
	assert.ok(s2.lock("scheduler", "solo", 10), "alone: back after LOCK_REST_S");
});

test("psid lookup returns the lobby record", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	s.put("L1", { id: "L1", map: "world" }, 1, 60);
	s.bindPsid("psid-1", "L1", 60);
	assert.deepEqual(s.lookupPsid("psid-1").value, { id: "L1", map: "world" });
	assert.equal(s.lookupPsid("nope").value, false);
	c.advance(61);
	assert.equal(s.lookupPsid("psid-1").value, false);
});

test("limits: a full store refuses new rows but keeps updating old ones", () => {
	const c = clock();
	const s = new LobbyStore(c.now, { lobbies: 2, psids: 2, locks: 2, maxTtl: 100, listMax: 10 });
	assert.ok(s.put("a", {}, 1, 60));
	assert.ok(s.put("b", {}, 1, 60));
	assert.equal(s.put("c", {}, 1, 60), null);
	assert.ok(s.put("a", { x: 1 }, 1, 60));
});

test("list keeps both ends when there are more rows than listMax", () => {
	const c = clock();
	const s = new LobbyStore(c.now, { lobbies: 100, psids: 10, locks: 10, maxTtl: 100, listMax: 4 });
	for (let i = 0; i < 10; i++) s.put(`r${i}`, { i }, i, 60);
	assert.deepEqual(
		s.list().map((r) => r.value.i),
		[0, 1, 8, 9],
	);
});

test("snapshot / restore keeps rows, versions move forward", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	const v = s.put("a", { n: 1 }, 1, 60)!;
	const t = new LobbyStore(c.now);
	t.restore(JSON.parse(JSON.stringify(s.snapshot())));
	assert.deepEqual(t.get("a"), { value: { n: 1 }, version: v });
	assert.ok(t.put("b", {}, 1, 60)! > v);
});

test("a lobby going open -> started is one match start with its humans", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	const seen: number[] = [];
	s.onStart = (m) => seen.push(m.humans);
	const v1 = s.put("L", { id: "L", status: "open", players: 3, max: 30, map: "world" }, 1, 60)!;
	const r = s.cas("L", v1, { id: "L", status: "started", players: 7, max: 30, map: "world" }, 1, 60);
	assert.ok(r.ok);
	if (r.ok) s.cas("L", r.version, { id: "L", status: "started", players: 5, max: 30, map: "world", beat: 1 }, 1, 60);
	assert.deepEqual(seen, [7], "beats after the start don't count again");
	assert.equal(s.starts.length, 1);
	assert.equal(s.starts[0].map, "world");
});

test("a new open lobby never starts more than 90 s out (older game servers too)", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	s.put("far", { id: "far", status: "open", starts: c.now() + 250, players: 0, max: 30 }, c.now() + 250, 600);
	s.put("near", { id: "near", status: "open", starts: c.now() + 60, players: 0, max: 30 }, c.now() + 60, 600);
	assert.equal((s.get("far").value as any).starts, c.now() + 90);
	assert.equal((s.get("near").value as any).starts, c.now() + 60);
	assert.deepEqual(
		s.list().map((r) => r.value.id),
		["near", "far"],
		"sorted by the clamped start",
	);
	assert.equal(s.counters.clamped, 1);
});

function lobby(s: LobbyStore, id: string, starts: number, extra: Record<string, unknown> = {}): void {
	s.put(id, { id, status: "open", starts, players: 0, max: 4, map: "world", ...extra }, starts, 600);
}

test("take: the soonest lobby of the kind with room, its seats in the ledger", () => {
	const c = clock();
	const t = c.now();
	const s = new LobbyStore(c.now);
	lobby(s, "late", t + 60);
	lobby(s, "soon", t + 30);
	lobby(s, "team", t + 20, { mode: "team", max: undefined, slots: 6 });
	lobby(s, "closing", t + 5);
	const spec = { mode: "ffa" as const, n: 1, uids: ["11"], at: t, closeBefore: t + 6, startBefore: t + 300 };
	const r = s.take(spec);
	assert.equal(r.id, "soon", "the soonest that still takes joins (not one closing)");
	assert.equal((r.value as any).players, 1);
	assert.deepEqual((r.value as any).seats, { "11": t });
	assert.equal(s.get("soon").version, r.version);
	// a party of 3 fits in "soon" (1 + 3 = 4); then "soon" is full and the next goes to "late"
	assert.equal(s.take({ ...spec, n: 3, uids: ["12", "13", "14"] }).id, "soon");
	assert.equal(s.take({ ...spec, uids: ["15"] }).id, "late");
	// a team game only for team takes, its size from `slots`
	const tr = s.take({ ...spec, mode: "team", n: 4, uids: ["16", "17", "18", "19"] });
	assert.equal(tr.id, "team");
	assert.equal(s.take({ ...spec, mode: "team", n: 3, uids: ["20", "21", "22"] }).value, false, "6 slots: 4 + 3 don't fit");
	assert.equal(s.counters.takeMisses, 1);
	// only the lobby asked for
	assert.equal(s.take({ ...spec, id: "soon", uids: ["23"] }).value, false, "full");
	// a record written with a wrong clock (far out) is skipped
	lobby(s, "wrong", t + 5000);
	s.lobbies.get("wrong")!.value.starts = t + 5000;
	assert.equal(s.take({ ...spec, n: 3, uids: ["24", "25", "26"] }).id, "late");
	assert.equal(s.take({ ...spec, n: 1, uids: ["27"] }).value, false, "late is full and wrong is too far out");
});

test("take: World's own lobbies for world takes, and for ffa ones only when they ask for them (modes)", () => {
	const c = clock();
	const t = c.now();
	const s = new LobbyStore(c.now);
	lobby(s, "world", t + 20, { mode: "world", max: undefined, slots: 50 });
	lobby(s, "ffa", t + 30);
	const spec = { mode: "ffa" as const, n: 1, uids: ["31"], at: t, closeBefore: t + 6, startBefore: t + 300 };
	assert.equal(s.take(spec).id, "ffa", "an ffa take without `modes` (servers before 2026-10-19): not a World seat");
	const g = s.take({ ...spec, mode: "world", uids: ["32"] });
	assert.equal(g.id, "world");
	assert.equal((g.value as any).players, 1);
	assert.equal(s.take({ ...spec, mode: "team", uids: ["33"] }).value, false, "nor a team seat");
	// its size from `slots`: 50 seats
	assert.equal(s.take({ ...spec, mode: "world", n: 8, uids: ["34", "35", "36", "37", "38", "39", "40", "41"] }).id, "world");
	// PUBLIC MATCH takes World's seats too (the game's LobbyRules.takes_from): the sooner one wins
	const both = { ...spec, modes: ["ffa", "world"] as ("ffa" | "world")[] };
	assert.equal(s.take({ ...both, uids: ["42"] }).id, "world", "ffa + world: the sooner World lobby");
	lobby(s, "ffa2", t + 10);
	assert.equal(s.take({ ...both, uids: ["43"] }).id, "ffa2", "ffa + world: a sooner free-for-all");
	assert.equal(s.take({ ...spec, mode: "world", uids: ["44"] }).id, "world", "a world take never gets a free-for-all");
});

test("take: an empty ledger written by Roblox as [] still takes", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	lobby(s, "L", c.now() + 30, { seats: [] });
	const r = s.take({ mode: "ffa", n: 1, uids: ["9"], at: 5, closeBefore: c.now(), startBefore: c.now() + 100 });
	assert.deepEqual((r.value as any).seats, { "9": 5 });
});

test("take: many takers on one lobby fill it exactly, then the next", () => {
	const c = clock();
	const t = c.now();
	const s = new LobbyStore(c.now);
	lobby(s, "A", t + 30, { max: 30 });
	lobby(s, "B", t + 40, { max: 30 });
	const got: Record<string, number> = {};
	for (let i = 0; i < 70; i++) {
		const r = s.take({ mode: "ffa", n: 1, uids: [String(i)], at: t, closeBefore: t + 6, startBefore: t + 300 });
		const k = r.id ?? "none";
		got[k] = (got[k] ?? 0) + 1;
	}
	assert.deepEqual(got, { A: 30, B: 30, none: 10 });
	assert.equal(Object.keys((s.get("A").value as any).seats).length, 30);
});

test("release: only seats in the ledger, once, while the lobby is open", () => {
	const c = clock();
	const t = c.now();
	const s = new LobbyStore(c.now);
	lobby(s, "L", t + 30);
	s.take({ mode: "ffa", n: 2, uids: ["1", "2"], at: t, closeBefore: t, startBefore: t + 300 });
	const r = s.release("L", ["1", "99"]);
	assert.equal(r.released, 1);
	assert.equal((r.value as any).players, 1);
	assert.equal(s.release("L", ["1"]).released, 0, "not twice");
	assert.equal((s.get("L").value as any).players, 1);
	assert.equal(s.release("nope", ["2"]).released, 0);
	// a started lobby keeps its count (the match server wrote the humans who started it)
	const v = s.get("L").version;
	s.cas("L", v, { ...(s.get("L").value as any), status: "started", players: 7 }, t + 30, 600);
	assert.equal(s.release("L", ["2"]).released, 0);
	assert.equal((s.get("L").value as any).players, 7);
	assert.equal(s.counters.seatsReleased, 1);
});

test("list(live): every open lobby and only the newest running matches", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	for (let i = 1; i <= 5; i++) s.put(`r${i}`, { id: `r${i}`, status: "started", starts: i }, i, 600);
	s.put("o1", { id: "o1", status: "open", starts: 100 }, 100, 600);
	s.put("o2", { id: "o2", status: "open", starts: 3 }, 3, 600);
	assert.deepEqual(
		s.list(2).map((r) => r.value.id),
		["o2", "r4", "r5", "o1"],
	);
	assert.equal(s.list().length, 7, "no `live`: every row (older hubs)");
	assert.equal(s.list(0).length, 2);
});

test("a team game's start and the live counts use its slots", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	const v1 = s.put("T", { id: "T", status: "open", players: 3, slots: 12, mode: "team", map: "luna", starts: c.now() + 30 }, 1, 60)!;
	assert.equal(s.liveNow().open[0].max, 12);
	s.cas("T", v1, { id: "T", status: "started", players: 9, slots: 12, mode: "team", map: "luna" }, 1, 60);
	assert.equal(s.starts[0].max, 12);
});

test("listJson: the list serialized once per change, the same answer as list()", () => {
	const c = clock();
	const s = new LobbyStore(c.now);
	const v1 = s.put("a", { id: "a", status: "open", players: 0, max: 30, starts: c.now() + 60 }, 2, 60)!;
	s.put("r", { id: "r", status: "started", starts: 1 }, 1, 60);
	const same = (live?: number): void => assert.equal(s.listJson(live), JSON.stringify(s.list(live)));
	same();
	same(0);
	const built = s.counters.listBuilt;
	assert.equal(s.listJson(), s.listJson(), "unchanged: reused");
	assert.equal(s.counters.listBuilt, built, "no rebuild while nothing changed");
	assert.ok((s.counters.listReused ?? 0) >= 2);
	// every kind of write shows at once
	s.cas("a", v1, { id: "a", status: "open", players: 4, max: 30, starts: c.now() + 60 }, 2, 60);
	same();
	s.put("b", { id: "b", status: "open", players: 1, max: 30, starts: c.now() + 70 }, 3, 60);
	same();
	s.remove("b");
	same();
	assert.ok(!s.listJson().includes('"b"'));
	// `live` answers are kept apart
	assert.notEqual(s.listJson(0), s.listJson());
	same(0);
	// a lease running out with no write: gone within LIST_CACHE_S
	s.put("short", { id: "short", status: "open", starts: c.now() + 5 }, 4, 1);
	assert.ok(s.listJson().includes('"short"'));
	c.advance(1.01);
	assert.ok(!s.listJson().includes('"short"'), "an expired row is not served from the cache");
	same();
	// with no change at all, a rebuild after LIST_CACHE_S still finds the same rows
	const before = s.listJson();
	c.advance(LobbyStore.LIST_CACHE_S + 0.01);
	assert.equal(s.listJson(), before);
});
