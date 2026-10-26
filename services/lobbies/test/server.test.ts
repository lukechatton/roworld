import { strict as assert } from "assert";
import * as http from "http";
import { test } from "node:test";
import { OldSecret, signRequest } from "../src/auth";
import { LobbyClient } from "../src/client";
import { loadConfig } from "../src/config";
import { FAIL_MAX } from "../src/statsAuth";
import { createServer } from "../src/server";
import { LobbyStore } from "../src/store";

const SECRET = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const PASSWORD = "correct horse battery";

interface Reply {
	status: number;
	headers: http.IncomingHttpHeaders;
	body: string;
}

function request(url: string, path: string, opts: { method?: string; headers?: Record<string, string>; body?: string } = {}): Promise<Reply> {
	return new Promise((resolve, reject) => {
		const req = http.request(`${url}${path}`, { method: opts.method ?? "GET", headers: opts.headers }, (res) => {
			let s = "";
			res.on("data", (d) => (s += d));
			res.on("end", () => resolve({ status: res.statusCode ?? 0, headers: res.headers, body: s }));
		});
		req.on("error", reject);
		if (opts.body !== undefined) req.write(opts.body);
		req.end();
	});
}

/** Signs in; returns the Cookie header for the next requests. */
async function login(url: string, password = PASSWORD, headers: Record<string, string> = {}): Promise<{ reply: Reply; cookie: string }> {
	const reply = await request(url, "/login", {
		method: "POST",
		headers: { "Content-Type": "application/x-www-form-urlencoded", ...headers },
		body: new URLSearchParams({ password, next: "/stats" }).toString(),
	});
	const set = reply.headers["set-cookie"]?.[0] ?? "";
	return { reply, cookie: set.split(";")[0] };
}

async function withServer(
	fn: (url: string, store: LobbyStore, flags: { enabled: boolean }) => Promise<void>,
	extra: { statsPassword?: () => string | null; localHealth?: boolean; oldSecret?: OldSecret | null } = {},
): Promise<void> {
	const store = new LobbyStore(() => Date.now() / 1000);
	const flags = { enabled: true };
	const server = createServer(store, { secret: SECRET, clockSkew: 120, flags: () => flags, log: () => {}, statsPassword: () => PASSWORD, ...extra });
	await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
	const port = (server.address() as { port: number }).port;
	try {
		await fn(`http://127.0.0.1:${port}`, store, flags);
	} finally {
		server.close();
	}
}

test("signed round trip: put, list, cas conflict, psid lookup, lock", async () => {
	await withServer(async (url) => {
		const c = new LobbyClient(url, SECRET);
		const put = await c.post<any>("/v1/lobbies/put", { jobId: "hubA", id: "L1", value: { id: "L1", players: 0, starts: 123 }, sort: 123, ttl: 60 });
		assert.equal(put.status, 200);
		assert.ok(put.verified);
		assert.ok(put.body.ok);
		const list = await c.post<any>("/v1/lobbies/list", { jobId: "hubA" });
		assert.equal(list.body.items.length, 1);
		assert.equal(list.body.enabled, true);
		assert.ok(typeof list.body.serverTime === "number");
		const v = list.body.items[0].version;
		const ok = await c.post<any>("/v1/lobbies/cas", { jobId: "hubB", id: "L1", expect: v, value: { id: "L1", players: 1, starts: 123 }, sort: 123, ttl: 900 });
		assert.equal(ok.body.ok, true);
		const stale = await c.post<any>("/v1/lobbies/cas", { jobId: "hubC", id: "L1", expect: v, value: { id: "L1", players: 1, starts: 123 }, sort: 123, ttl: 900 });
		assert.equal(stale.body.ok, false);
		assert.equal(stale.body.err, "conflict");
		assert.equal(stale.body.value.players, 1);
		await c.post("/v1/psid/bind", { jobId: "hubA", psid: "ps-1", id: "L1", ttl: 60 });
		const look = await c.post<any>("/v1/psid/lookup", { jobId: "match1", role: "match", psid: "ps-1" });
		assert.equal(look.body.value.id, "L1");
		const l1 = await c.post<any>("/v1/locks/acquire", { jobId: "hubA", name: "scheduler", ttl: 10 });
		const l2 = await c.post<any>("/v1/locks/acquire", { jobId: "hubB", name: "scheduler", ttl: 10 });
		assert.equal(l1.body.got, true);
		assert.equal(l2.body.got, false);
	});
});

test("auth: wrong secret, stale clock (with the time), replay are refused", async () => {
	await withServer(async (url) => {
		const bad = new LobbyClient(url, "f".repeat(64));
		const r1 = await bad.post<any>("/v1/lobbies/list", { jobId: "x" });
		assert.equal(r1.status, 401);
		assert.equal(r1.body.serverTime, undefined, "a wrong signature learns nothing");
		const skewed = new LobbyClient(url, SECRET, () => Math.floor(Date.now() / 1000) - 900);
		const r2 = await skewed.post<any>("/v1/lobbies/list", { jobId: "x" });
		assert.equal(r2.status, 401);
		assert.ok(Math.abs(r2.body.serverTime - Date.now() / 1000) < 5, "a signed request 15 min off learns the time");
		// replay: the same headers and body twice
		const body = JSON.stringify({ protocol: 1, jobId: "x" });
		const { signRequest } = await import("../src/auth");
		const ts = String(Math.floor(Date.now() / 1000));
		const nonce = "abcdefabcdefabcdefabcdefabcdef12";
		const headers = { "Content-Type": "application/json", "X-TM-Ts": ts, "X-TM-Nonce": nonce, "X-TM-Sig": signRequest(SECRET, ts, nonce, "POST", "/v1/lobbies/list", body) };
		const send = (): Promise<number> =>
			new Promise((resolve, reject) => {
				const req = http.request(`${url}/v1/lobbies/list`, { method: "POST", headers }, (res) => {
					res.resume();
					res.on("end", () => resolve(res.statusCode ?? 0));
				});
				req.on("error", reject);
				req.end(body);
			});
		assert.equal(await send(), 200);
		assert.equal(await send(), 401);
	});
});

test("a rotation: the old secret works (its replies signed with it) until RL_SECRET_OLD_UNTIL, then not", async () => {
	const OLD = "f".repeat(64);
	const now = Math.floor(Date.now() / 1000);
	await withServer(
		async (url) => {
			const current = await new LobbyClient(url, SECRET).post<any>("/v1/lobbies/list", { jobId: "new" });
			assert.equal(current.status, 200);
			assert.ok(current.verified);
			const old = await new LobbyClient(url, OLD).post<any>("/v1/lobbies/list", { jobId: "old" });
			assert.equal(old.status, 200);
			assert.ok(old.verified, "a server still on the old secret can check the reply");
			const other = await new LobbyClient(url, "e".repeat(64)).post<any>("/v1/lobbies/list", { jobId: "x" });
			assert.equal(other.status, 401);
		},
		{ oldSecret: { secret: OLD, until: now + 60 } },
	);
	await withServer(
		async (url) => {
			const old = await new LobbyClient(url, OLD).post<any>("/v1/lobbies/list", { jobId: "old" });
			assert.equal(old.status, 401);
		},
		{ oldSecret: { secret: OLD, until: now } },
	);
	const cfg = (env: Record<string, string>) => loadConfig("/nonexistent", { RL_SECRET: SECRET, ...env }).oldSecret;
	assert.deepEqual(cfg({ RL_SECRET_OLD: OLD, RL_SECRET_OLD_UNTIL: "2000000000" }), { secret: OLD, until: 2000000000 });
	assert.equal(cfg({ RL_SECRET_OLD: OLD }), null, "no end time: never accepted");
	assert.equal(cfg({ RL_SECRET_OLD_UNTIL: "2000000000" }), null);
});

test("validation: bad ids, oversized values, unknown routes", async () => {
	await withServer(async (url) => {
		const c = new LobbyClient(url, SECRET);
		const r1 = await c.post<any>("/v1/lobbies/put", { jobId: "h", id: "bad id!", value: {}, sort: 1, ttl: 60 });
		assert.equal(r1.status, 400);
		const r2 = await c.post<any>("/v1/lobbies/put", { jobId: "h", id: "L", value: { blob: "x".repeat(5000) }, sort: 1, ttl: 60 });
		assert.equal(r2.status, 400);
		const r3 = await c.post<any>("/v1/nope", { jobId: "h" });
		assert.equal(r3.status, 404);
	});
});

test("a hub's list leaves out the seat ledgers; a match server's or a tool's keeps them", async () => {
	await withServer(async (url) => {
		const c = new LobbyClient(url, SECRET);
		const value = { id: "L2", players: 2, starts: 200, code: "abc", seats: { "111": 1, "222": 2 } };
		await c.post<any>("/v1/lobbies/put", { jobId: "hubA", id: "L2", value, sort: 200, ttl: 60 });
		const hub = await c.post<any>("/v1/lobbies/list", { jobId: "hubA", role: "hub", live: 64 });
		assert.ok(hub.verified);
		assert.equal(hub.body.items[0].value.seats, undefined);
		assert.equal(hub.body.items[0].value.code, "abc");
		assert.equal(hub.body.items[0].value.players, 2);
		const asked = await c.post<any>("/v1/lobbies/list", { jobId: "tool", summary: true });
		assert.equal(asked.body.items[0].value.seats, undefined);
		const match = await c.post<any>("/v1/lobbies/list", { jobId: "m1", role: "match" });
		assert.deepEqual(match.body.items[0].value.seats, { "111": 1, "222": 2 });
		const tool = await c.post<any>("/v1/lobbies/list", { jobId: "tool" });
		assert.deepEqual(tool.body.items[0].value.seats, { "111": 1, "222": 2 });
		// (and the record itself keeps them: a get, as a match server reads its own)
		const got = await c.post<any>("/v1/lobbies/get", { jobId: "m1", role: "match", id: "L2" });
		assert.deepEqual(got.body.value.seats, { "111": 1, "222": 2 });
	});
});

test("the kill switch shows in list replies", async () => {
	await withServer(async (url, _store, flags) => {
		const c = new LobbyClient(url, SECRET);
		flags.enabled = false;
		const r = await c.post<any>("/v1/lobbies/list", { jobId: "h" });
		assert.equal(r.body.enabled, false);
	});
});

test("health: in full to this box, a signed-in browser or a signed request; {ok:true} to anyone else", async () => {
	await withServer(async (url) => {
		const c = new LobbyClient(url, SECRET);
		await c.post("/v1/lobbies/list", { jobId: "hub1" });
		await c.post("/v1/lobbies/list", { jobId: "hub2" });
		await c.post("/v1/psid/lookup", { jobId: "m1", role: "match", psid: "p" });
		const h = JSON.parse((await request(url, "/health")).body);
		assert.equal(h.hubs, 2);
		assert.equal(h.matchServers, 1);
		assert.equal(h.service, "rofront-lobbies");
		assert.deepEqual(h.via, { cloudflare: 0, direct: 3 });
	});
	await withServer(
		async (url) => {
			assert.equal((await request(url, "/health")).body, '{"ok":true}', "trimmed for a stranger");
			const { cookie } = await login(url);
			assert.equal(JSON.parse((await request(url, "/health", { headers: { Cookie: cookie } })).body).service, "rofront-lobbies");
			const ts = String(Math.floor(Date.now() / 1000));
			const nonce = "health-nonce-0123456789";
			const sig = signRequest(SECRET, ts, nonce, "GET", "/health", "");
			const signed = await request(url, "/health", { headers: { "X-TM-Ts": ts, "X-TM-Nonce": nonce, "X-TM-Sig": sig } });
			assert.equal(JSON.parse(signed.body).service, "rofront-lobbies", "signed");
			const forged = await request(url, "/health", { headers: { "X-TM-Ts": ts, "X-TM-Nonce": "health-nonce-9999999999", "X-TM-Sig": sig } });
			assert.equal(forged.body, '{"ok":true}', "a bad signature");
		},
		{ localHealth: false },
	);
});

test("the stats pages need a sign-in; a right password gets a 30-day cookie", async () => {
	await withServer(async (url) => {
		const page = await request(url, "/stats");
		assert.equal(page.status, 302);
		assert.equal(page.headers.location, "/login?next=%2Fstats");
		assert.equal((await request(url, "/stats.json")).status, 401);
		assert.equal((await request(url, "/stats/events")).status, 401);
		assert.equal((await request(url, "/")).headers.location, "/stats");
		const form = await request(url, "/login?next=/stats");
		assert.equal(form.status, 200);
		assert.ok(form.body.includes('name="password"') && form.body.includes('value="/stats"'));
		const wrong = await login(url, "not the password");
		assert.equal(wrong.reply.status, 401);
		assert.equal(wrong.cookie, "");
		assert.ok(wrong.reply.body.includes("Wrong password"));
		const ok = await login(url);
		assert.equal(ok.reply.status, 303);
		assert.equal(ok.reply.headers.location, "/stats");
		const set = ok.reply.headers["set-cookie"]?.[0] ?? "";
		for (const attr of ["HttpOnly", "Secure", "SameSite=Lax", `Max-Age=${30 * 86400}`, "Path=/"]) assert.ok(set.includes(attr), attr);
		assert.equal((await request(url, "/stats", { headers: { Cookie: ok.cookie } })).status, 200);
		assert.equal((await request(url, "/stats.json", { headers: { Cookie: ok.cookie } })).status, 200);
		assert.equal((await request(url, "/login", { headers: { Cookie: ok.cookie } })).status, 302, "signed in already");
		// a forged or tampered cookie
		const [exp, sig] = ok.cookie.split("=")[1].split(".");
		const later = `rl_stats=${Number(exp) + 999}.${sig}`;
		assert.equal((await request(url, "/stats.json", { headers: { Cookie: later } })).status, 401);
		// signing out
		const out = await request(url, "/logout");
		assert.equal(out.status, 303);
		assert.ok((out.headers["set-cookie"]?.[0] ?? "").includes("Max-Age=0"));
		// no open redirect
		const evil = await request(url, "/login", {
			method: "POST",
			headers: { "Content-Type": "application/x-www-form-urlencoded" },
			body: new URLSearchParams({ password: PASSWORD, next: "https://evil.example/" }).toString(),
		});
		assert.equal(evil.headers.location, "/stats");
	});
});

test("a changed password signs everyone out; no password: the pages stay locked", async () => {
	let pw: string | null = PASSWORD;
	await withServer(
		async (url) => {
			const { cookie } = await login(url);
			assert.equal((await request(url, "/stats.json", { headers: { Cookie: cookie } })).status, 200);
			pw = "a whole new password";
			assert.equal((await request(url, "/stats.json", { headers: { Cookie: cookie } })).status, 401);
			pw = "surf";
			const short = await login(url, "surf");
			assert.equal(short.reply.status, 303, "a short password works");
			assert.equal((await request(url, "/stats.json", { headers: { Cookie: short.cookie } })).status, 200);
			pw = null;
			assert.equal((await login(url, "")).reply.status, 503);
			assert.equal((await request(url, "/login")).status, 503);
			assert.equal((await request(url, "/stats.json")).status, 401);
		},
		{ statsPassword: () => pw },
	);
});

test("failed sign-ins are throttled per client (Cloudflare's client IP, behind the proxy)", async () => {
	await withServer(async (url) => {
		const a = { "CF-Connecting-IP": "203.0.113.7" };
		for (let i = 0; i < FAIL_MAX; i++) assert.equal((await login(url, "guess " + i, a)).reply.status, 401);
		assert.equal((await login(url, PASSWORD, a)).reply.status, 429, "even the right password, for a while");
		assert.equal((await login(url, PASSWORD, { "CF-Connecting-IP": "203.0.113.8" })).reply.status, 303, "another client");
	});
});

test("stats page and JSON are aggregated", async () => {
	await withServer(async (url, store) => {
		store.starts.push({ t: Date.now() / 1000 - 60, humans: 11, max: 30, map: "world" });
		const { cookie } = await login(url);
		const get = (p: string): Promise<{ status: number; type: string; body: string }> =>
			new Promise((resolve, reject) => {
				http.get(`${url}${p}`, { headers: { Cookie: cookie } }, (res) => {
					let s = "";
					res.on("data", (d) => (s += d));
					res.on("end", () => resolve({ status: res.statusCode ?? 0, type: String(res.headers["content-type"]), body: s }));
				}).on("error", reject);
			});
		const page = await get("/stats");
		assert.equal(page.status, 200);
		assert.ok(page.type.startsWith("text/html") && page.body.includes("Players per public match") && !page.body.includes("Goal") && !/humans/i.test(page.body.replace(/s\.best\.humans|m\.humans/g, "")));
		assert.ok(page.body.includes("Players online now"), "the total on top");
		const json = await get("/stats.json");
		const st = JSON.parse(json.body);
		assert.equal(st.last24h.matches, 1);
		assert.equal(st.last24h.avg, 11);
	});
});

test("the live stream sends the stats at once and again after a change", async () => {
	await withServer(async (url, store) => {
		const frames: string[] = [];
		const { cookie } = await login(url);
		const req = http.get(`${url}/stats/events`, { headers: { Cookie: cookie } }, (res) => {
			assert.equal(res.headers["content-type"], "text/event-stream");
			res.setEncoding("utf8");
			res.on("data", (d: string) => {
				for (const part of d.split("\n\n")) if (part.includes("data: ")) frames.push(part.slice(part.indexOf("data: ") + 6));
			});
		});
		const until = async (n: number): Promise<void> => {
			for (let i = 0; i < 60 && frames.length < n; i++) await new Promise((r) => setTimeout(r, 50));
		};
		await until(1);
		assert.equal(frames.length, 1, "the stats on connect");
		const first = JSON.parse(frames[0]);
		assert.equal(first.now.waiting, 0);
		store.put("L", { id: "L", status: "open", players: 4, max: 30, map: "world", starts: Date.now() / 1000 + 60 }, 1, 60);
		await until(2);
		assert.equal(frames.length, 2, "pushed after the write (within ~1 s)");
		const second = JSON.parse(frames[1]);
		assert.equal(second.now.waiting, 4);
		assert.equal(second.now.open[0].map, "world");
		req.destroy();
	});
});

test("hubs' presence reaches the live stats; match servers' is ignored", async () => {
	const { Presence } = await import("../src/presence");
	const store = new LobbyStore(() => Date.now() / 1000);
	const presence = new Presence(() => Date.now() / 1000);
	const server = createServer(store, { secret: SECRET, clockSkew: 120, flags: () => ({ enabled: true }), log: () => {}, presence, statsPassword: () => PASSWORD });
	await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
	const url = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
	try {
		const c = new LobbyClient(url, SECRET);
		await c.post("/v1/lobbies/list", { jobId: "hub1", role: "hub", presence: { players: 9, solo: 5, solo_easy: 3, solo_medium: 2, solo_hard: 0, title: 4 } });
		await c.post("/v1/lobbies/list", { jobId: "m1", role: "match", presence: { players: 30, solo: 30, title: 0 } });
		const bad = await c.post<any>("/v1/lobbies/list", { jobId: "hub2", role: "hub", presence: { players: -1 } });
		assert.equal(bad.status, 400);
		const { cookie } = await login(url);
		const st = await new Promise<any>((resolve, reject) => {
			http.get(`${url}/stats.json`, { headers: { Cookie: cookie } }, (res) => {
				let s = "";
				res.on("data", (d) => (s += d));
				res.on("end", () => resolve(JSON.parse(s)));
			}).on("error", reject);
		});
		assert.equal(st.now.solo, 5);
		assert.equal(st.now.soloEasy, 3);
		assert.equal(st.now.title, 4);
		assert.equal(st.now.hubs, 1);
	} finally {
		server.close();
	}
});

test("take / release / list(live) over signed HTTP", async () => {
	await withServer(async (url) => {
		const c = new LobbyClient(url, SECRET);
		const t = Math.floor(Date.now() / 1000);
		await c.post("/v1/lobbies/put", { jobId: "hubA", id: "L1", value: { id: "L1", status: "open", players: 0, max: 2, starts: t + 30 }, sort: t + 30, ttl: 60 });
		await c.post("/v1/lobbies/put", { jobId: "hubA", id: "R1", value: { id: "R1", status: "started", players: 5, max: 30, starts: t - 60 }, sort: t - 60, ttl: 60 });
		const spec = { jobId: "hubB", mode: "ffa", n: 2, uids: ["101", "102"], at: t, closeBefore: t + 6, startBefore: t + 300 };
		const a = await c.post<any>("/v1/lobbies/take", spec);
		assert.ok(a.verified);
		assert.equal(a.body.ok, true);
		assert.equal(a.body.value.id, "L1");
		assert.equal(a.body.value.players, 2);
		const b = await c.post<any>("/v1/lobbies/take", { ...spec, n: 1, uids: ["103"] });
		assert.equal(b.body.ok, true);
		assert.equal(b.body.value, false, "full: no lobby has room");
		const r = await c.post<any>("/v1/lobbies/release", { jobId: "match1", role: "match", id: "L1", uids: ["101"] });
		assert.equal(r.body.released, 1);
		assert.equal(r.body.value.players, 1);
		const live0 = await c.post<any>("/v1/lobbies/list", { jobId: "hubA", live: 0 });
		assert.deepEqual(
			live0.body.items.map((i: any) => i.value.id),
			["L1"],
		);
		const all = await c.post<any>("/v1/lobbies/list", { jobId: "hubA" });
		assert.equal(all.body.items.length, 2, "without `live` (older hubs): every row");
		// validation
		for (const bad of [{ mode: "x" }, { modes: ["x"] }, { modes: "ffa" }, { modes: ["ffa", "world", "team", "ffa"] }, { n: 0 }, { n: 9 }, { uids: ["no spaces"] }, { at: "now" }, { id: "../x" }]) {
			const res = await c.post<any>("/v1/lobbies/take", { ...spec, ...bad });
			assert.equal(res.status, 400, JSON.stringify(bad));
		}
		// World's own kind is accepted (no world lobby here: no room, not an error)
		const gt = await c.post<any>("/v1/lobbies/take", { ...spec, mode: "world", uids: ["104"] });
		assert.equal(gt.status, 200);
		assert.equal(gt.body.value, false);
		// a free-for-all join that takes World's lobbies too (modes), and Roblox's [] for none
		await c.post("/v1/lobbies/put", { jobId: "hubA", id: "W1", value: { id: "W1", status: "open", mode: "world", players: 0, slots: 50, starts: t + 20 }, sort: t + 20, ttl: 60 });
		const wt = await c.post<any>("/v1/lobbies/take", { ...spec, modes: ["ffa", "world"], n: 1, uids: ["105"] });
		assert.equal(wt.status, 200);
		assert.equal(wt.body.value.id, "W1", "PUBLIC MATCH: a seat in World's lobby");
		const none = await c.post<any>("/v1/lobbies/take", { ...spec, modes: [], n: 1, uids: ["106"] });
		assert.equal(none.status, 200);
		assert.equal(none.body.value.id, "L1", "modes [] is mode alone: L1 had a seat back");
		assert.equal((await c.post<any>("/v1/lobbies/list", { jobId: "hubA", live: -1 })).status, 400);
	});
});
