import { strict as assert } from "assert";
import { test } from "node:test";
import { band, buildStats, summarize } from "../src/stats";

test("summaries: average, median, p90, max", () => {
	const s = summarize([3, 1, 8, 20, 5].map((h, i) => ({ t: i, humans: h, max: 30, map: "m" })));
	assert.deepEqual(s, { matches: 5, avg: 7.4, median: 5, p90: 20, max: 20, humans: 37 });
	assert.equal(summarize([]).matches, 0);
});

test("bands", () => {
	assert.equal(band(1), "1");
	assert.equal(band(4), "2-4");
	assert.equal(band(19), "10-19");
	assert.equal(band(50), "50+");
});

test("stats windows, hourly and daily buckets, best", () => {
	const now = 1_000_000_000;
	const starts = [
		{ t: now - 40 * 24 * 3600, humans: 49, max: 50, map: "old" }, // outside 30 days
		{ t: now - 3 * 24 * 3600, humans: 12, max: 30, map: "a" },
		{ t: now - 2 * 3600, humans: 4, max: 30, map: "b" },
		{ t: now - 600, humans: 9, max: 30, map: "c" },
	];
	const st = buildStats(starts, now);
	assert.equal(st.lastHour.matches, 1);
	assert.equal(st.last24h.matches, 2);
	assert.equal(st.last7d.matches, 3);
	assert.equal(st.last30d.matches, 3);
	assert.equal(st.best!.humans, 49);
	assert.equal(st.hourly.length, 48);
	assert.equal(st.daily.length, 30);
	assert.equal(st.hourly.reduce((a, h) => a + h.matches, 0), 2);
	assert.equal(st.bands24h["5-9"], 1);
	assert.equal(st.bands24h["2-4"], 1);
	assert.equal(st.recent[0].map, "c");
});
