import { strict as assert } from "assert";
import { test } from "node:test";
import { Presence } from "../src/presence";

test("hub counts add up; a silent hub drops out", () => {
	let t = 1000;
	const p = new Presence(() => t);
	p.report("hubA", { players: 10, solo: 6, soloEasy: 4, soloMedium: 2, soloHard: 0, title: 4 });
	p.report("hubB", { players: 5, solo: 1, soloEasy: 0, soloMedium: 0, soloHard: 1, title: 4 });
	let s = p.totals();
	assert.deepEqual([s.hubs, s.players, s.solo, s.soloEasy, s.soloHard, s.title], [2, 15, 7, 4, 1, 8]);
	t += 25;
	p.report("hubB", { players: 5, solo: 2, soloEasy: 0, soloMedium: 1, soloHard: 1, title: 3 });
	s = p.totals();
	assert.deepEqual([s.hubs, s.solo], [1, 2], "hub A silent for 25 s: gone");
});

test("samples and the averaged series", () => {
	let t = 100_000;
	const p = new Presence(() => t);
	const seen: number[] = [];
	p.onSample = (x) => seen.push(x.solo);
	p.report("h", { players: 3, solo: 3, soloEasy: 3, soloMedium: 0, soloHard: 0, title: 0 });
	p.sample(2, 5);
	t += 60;
	p.report("h", { players: 1, solo: 1, soloEasy: 1, soloMedium: 0, soloHard: 0, title: 0 });
	p.sample(0, 5);
	assert.deepEqual(seen, [3, 1]);
	const series = p.series(1, 1);
	assert.equal(series.length, 1);
	assert.equal(series[0].solo, 2, "averaged over the bucket");
	assert.equal(series[0].playing, 5);
});
