import { strict as assert } from "assert";
import { test } from "node:test";
import { fpsBand, parseReport, Perf } from "../src/perf";
import { Invalid } from "../src/validate";

// a report as ServerPerf.luau sends it
const wire = (o: Record<string, unknown> = {}): Record<string, unknown> => ({
	role: "match",
	fps: 59.8,
	slow_frames: 0,
	slow_share: 0,
	worst_ms: 40,
	window_s: 60,
	steps: 600,
	step_ms_avg: 8.2,
	step_ms_p99: 31.5,
	step_ms_max: 44,
	encode_ms_avg: 1.1,
	catchup_frames: 2,
	budget_stops: 0,
	stage: "playing",
	humans: 48,
	players: 48,
	map: "world",
	mode: "world",
	max: 50,
	minute: 12.5,
	attacks: 140,
	mem_mb: 512.3,
	age_min: 14.2,
	version: 114,
	...o,
});

test("a report is checked field by field", () => {
	const r = parseReport(wire());
	assert.equal(r.role, "match");
	assert.equal(r.stepMsP99, 31.5);
	assert.equal(r.map, "world");
	const hub = parseReport({ role: "hub", fps: 60, stage: "idle", players: 30, mem_mb: 300, age_min: 100, version: 114 });
	assert.equal(hub.map, null, "a hub has no match");
	assert.equal(hub.minute, null);
	assert.throws(() => parseReport(wire({ role: "solo" })), Invalid);
	assert.throws(() => parseReport(wire({ fps: -1 })), Invalid);
	assert.throws(() => parseReport(wire({ map: "<script>" })), Invalid);
	assert.throws(() => parseReport(wire({ steps: 1.5 })), Invalid);
	assert.throws(() => parseReport("x"), Invalid);
});

test("counts by role and frame rate; the slowest first; a silent server drops out", () => {
	let t = 1000;
	const p = new Perf(() => t);
	p.report("aaaaaaaa-1", parseReport(wire({ fps: 60 })));
	p.report("bbbbbbbb-2", parseReport(wire({ fps: 1.4 })));
	p.report("cccccccc-3", parseReport(wire({ fps: 24 })));
	p.report("dddddddd-4", parseReport({ role: "hub", fps: 2, players: 20, mem_mb: 300, age_min: 100, version: 114 }));
	let s = p.summary(2);
	assert.equal(s.servers, 4);
	assert.deepEqual(s.byRole, { hub: 1, match: 3 });
	assert.equal(s.bands.match["55+"], 1);
	assert.equal(s.bands.match["10-30"], 1);
	assert.equal(s.bands.match["under 3"], 1);
	assert.equal(s.bands.hub["under 3"], 1);
	assert.deepEqual(
		s.slowest.map((x) => x.job),
		["bbbbbbbb", "dddddddd"],
	);
	t += Perf.STALE_S + 1;
	p.report("aaaaaaaa-1", parseReport(wire({ fps: 60 })));
	s = p.summary();
	assert.equal(s.servers, 1, "the others went quiet");
	assert.equal(fpsBand(9.99), "3-10");
});

test("a slow server is logged at most every LOG_EVERY_S; samples count the slow ones", () => {
	let t = 5000;
	const p = new Perf(() => t);
	const logged: string[] = [];
	p.onSlow = (job) => logged.push(job);
	p.report("slow", parseReport(wire({ fps: 3 })));
	p.report("fast", parseReport(wire({ fps: 60 })));
	t += 60;
	p.report("slow", parseReport(wire({ fps: 2 })));
	assert.deepEqual(logged, ["slow"], "once within LOG_EVERY_S");
	t += Perf.LOG_EVERY_S;
	p.report("slow", parseReport(wire({ fps: 2 })));
	p.report("fast", parseReport(wire({ fps: 60 })));
	assert.deepEqual(logged, ["slow", "slow"]);
	const seen: number[] = [];
	p.onSample = (x) => seen.push(x.slowMatches);
	const smp = p.sample();
	assert.deepEqual([smp.matches, smp.slowMatches, smp.hubs, smp.slowHubs], [2, 1, 0, 0]);
	assert.deepEqual(seen, [1]);
});

test("hand-offs and lost Stars: the servers' latest minutes added up, in the summary and the samples", () => {
	const t = 9000;
	const p = new Perf(() => t);
	p.report("hub-1", parseReport({ role: "hub", fps: 60, players: 30, mem_mb: 300, age_min: 100, version: 116, handoff_hits: 40, handoff_misses: 2, handoff_none: 5, handoff_sent: 38 }));
	p.report("match-1", parseReport(wire({ handoff_hits: 48, handoff_sent: 3, stars_lost: 1, stars_lost_amount: 120 })));
	p.report("old-1", parseReport(wire({ version: 115 })));
	const s = p.summary();
	assert.deepEqual(s.handoff, { hits: 88, misses: 2, none: 5, sent: 41 });
	assert.deepEqual(s.starsLost, { payouts: 1, stars: 120 });
	const smp = p.sample();
	assert.deepEqual(smp.handoff, s.handoff);
	assert.deepEqual(smp.starsLost, s.starsLost);
	assert.throws(() => parseReport(wire({ handoff_hits: -1 })), Invalid);
	assert.throws(() => parseReport(wire({ stars_lost: 0.5 })), Invalid);
});
