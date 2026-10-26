// HTTP front of the lobby store: signed JSON POSTs under /v1/*; the stats pages behind a login
// (statsAuth); GET /health, in full only to this box, a signed-in browser or a signed request.
// docs/lobby-service.md "Endpoints".
import * as http from "http";
import { OldSecret, signResponse, Verifier } from "./auth";
import type { Presence } from "./presence";
import { buildStats } from "./stats";
import { clientIp, COOKIE_DAYS, cookieHeader, isLoopback, loginPage, safeNext, StatsAuth, viaCloudflare } from "./statsAuth";
import { STATS_PAGE } from "./statsPage";
import type { Kind, LobbyStore } from "./store";
import { arr, ID_RE, int, Invalid, JOB_RE, num, obj, optStr, str } from "./validate";

const MAX_BODY = 64 * 1024;
const MAX_VALUE = 4096; // bytes of JSON per lobby record
const PSID_RE = /^[0-9A-Za-z_-]{1,64}$/;
const NAME_RE = /^[0-9A-Za-z_.:-]{1,64}$/;
const UID_RE = /^[0-9A-Za-z_-]{1,24}$/; // a Roblox user id (tests: any short id)
const PROTOCOL = 1;

type Handler = (body: Record<string, unknown>, jobId: string) => unknown;

/** A reply already serialized: sent (and signed) as is, not through JSON.stringify. */
export class RawJson {
	constructor(readonly json: string) {}
}

function record(v: unknown): Record<string, unknown> {
	const o = obj(v, "value");
	const s = JSON.stringify(o);
	if (s.length > MAX_VALUE) throw new Invalid(`value: too large (${s.length} > ${MAX_VALUE})`);
	return JSON.parse(s) as Record<string, unknown>;
}

export interface Seen {
	hub: Map<string, number>;
	match: Map<string, number>;
}

function hubCounts(v: unknown): { players: number; solo: number; soloEasy: number; soloMedium: number; soloHard: number; title: number } {
	const o = obj(v, "presence");
	const n = (k: string): number => int(o[k] ?? 0, `presence.${k}`, 0, 1000);
	return { players: n("players"), solo: n("solo"), soloEasy: n("solo_easy"), soloMedium: n("solo_medium"), soloHard: n("solo_hard"), title: n("title") };
}

export function buildRoutes(store: LobbyStore, flags: () => { enabled: boolean }, now: () => number, seen: Seen, presence?: Presence): Record<string, Handler> {
	const mark = (b: Record<string, unknown>, jobId: string): void => {
		(b.role === "match" ? seen.match : seen.hub).set(jobId, now());
	};
	const ttl = (v: unknown): number => num(v, "ttl", 1, 24 * 3600);
	return {
		"/v1/lobbies/list": (b, jobId) => {
			mark(b, jobId);
			if (presence && b.presence !== undefined && b.role !== "match") presence.report(jobId, hubCounts(b.presence));
			// `live`: only that many running matches (the newest), with every open lobby (hubs from 2026-10-11)
			const live = b.live === undefined ? undefined : int(b.live, "live", 0, 300);
			// a hub's list (or one asking for `summary`): the rows without their seat ledgers, which hubs
			// never read and which were 79% of the reply's bytes (2026-10-24: 137 KB to each of ~1,100
			// hubs every 3 s, the service at 92% of its core). Hubs have sent role "hub" since v44, so
			// every live server gets the light list at once; a match server or a tool gets them all.
			const summary = b.summary === true || b.role === "hub";
			// (the rows from the store's cache, serialized once per change; the rest is per request)
			return new RawJson(`{"ok":true,"enabled":${flags().enabled ? "true" : "false"},"items":${store.listJson(live, summary)},"serverTime":${JSON.stringify(now())}}`);
		},
		"/v1/lobbies/get": (b, jobId) => {
			mark(b, jobId);
			return { ok: true, ...store.get(str(b.id, "id", 64, ID_RE)) };
		},
		"/v1/lobbies/put": (b, jobId) => {
			mark(b, jobId);
			const version = store.put(str(b.id, "id", 64, ID_RE), record(b.value), num(b.sort, "sort", 0, 1e11), ttl(b.ttl));
			return version === null ? { ok: false, err: "full" } : { ok: true, version };
		},
		"/v1/lobbies/cas": (b, jobId) => {
			mark(b, jobId);
			return store.cas(str(b.id, "id", 64, ID_RE), int(b.expect, "expect", 0, Number.MAX_SAFE_INTEGER), record(b.value), num(b.sort, "sort", 0, 1e11), ttl(b.ttl));
		},
		"/v1/lobbies/take": (b, jobId) => {
			mark(b, jobId);
			const kind = (m: unknown): Kind | null => (m === "team" ? "team" : m === "ffa" ? "ffa" : m === "world" ? "world" : null);
			const mode = kind(b.mode);
			if (mode === null) throw new Invalid("mode: ffa, team or world expected");
			// (optional: every kind the join takes, the game's LobbyRules.takes_from; [] from Roblox's
			// JSONEncode of an empty table counts as none)
			const modes =
				b.modes === undefined || b.modes === null
					? []
					: arr(b.modes, "modes", 3, (m, i) => {
							const k = kind(m);
							if (k === null) throw new Invalid(`modes[${i}]: ffa, team or world expected`);
							return k;
						});
			const n = int(b.n, "n", 1, 8);
			const uids = arr(b.uids, "uids", 8, (u, i) => str(u, `uids[${i}]`, 24, UID_RE));
			const id = optStr(b.id, "id", 64, ID_RE);
			const r = store.take({
				mode,
				...(modes.length > 0 ? { modes } : {}),
				n,
				uids,
				at: num(b.at, "at", 0, 1e11),
				closeBefore: num(b.closeBefore, "closeBefore", 0, 1e11),
				startBefore: num(b.startBefore, "startBefore", 0, 1e11),
				...(id !== null ? { id } : {}),
			});
			return { ok: true, value: r.value, version: r.version };
		},
		"/v1/lobbies/release": (b, jobId) => {
			mark(b, jobId);
			const uids = arr(b.uids, "uids", 64, (u, i) => str(u, `uids[${i}]`, 24, UID_RE));
			return { ok: true, ...store.release(str(b.id, "id", 64, ID_RE), uids) };
		},
		"/v1/lobbies/remove": (b, jobId) => {
			mark(b, jobId);
			store.remove(str(b.id, "id", 64, ID_RE));
			return { ok: true };
		},
		"/v1/locks/acquire": (b, jobId) => {
			mark(b, jobId);
			return { ok: true, got: store.lock(str(b.name, "name", 64, NAME_RE), jobId, num(b.ttl, "ttl", 1, 300)) };
		},
		"/v1/psid/bind": (b, jobId) => {
			mark(b, jobId);
			const done = store.bindPsid(str(b.psid, "psid", 64, PSID_RE), str(b.id, "id", 64, ID_RE), ttl(b.ttl));
			return done ? { ok: true } : { ok: false, err: "full" };
		},
		"/v1/psid/lookup": (b, jobId) => {
			mark(b, jobId);
			return { ok: true, ...store.lookupPsid(str(b.psid, "psid", 64, PSID_RE)) };
		},
		"/v1/status": () => ({ ok: true, flags: flags(), counts: store.counts(), counters: store.counters, list: store.list() }),
	};
}

export interface ServerOptions {
	presence?: Presence;
	secret: string;
	/** The previous secret while a rotation is under way (RL_SECRET_OLD / RL_SECRET_OLD_UNTIL). */
	oldSecret?: OldSecret | null;
	clockSkew: number;
	flags: () => { enabled: boolean };
	log: (level: "debug" | "info" | "warn", msg: string) => void;
	nowSec?: () => number; // for tests
	/** The stats pages' password (STATS_PASSWORD in .env; null: the pages stay locked). */
	statsPassword?: () => string | null;
	/** /health in full to this box itself (deploy.sh, flag.sh, watch.sh); tests turn it off. */
	localHealth?: boolean;
}

export function createServer(store: LobbyStore, opts: ServerOptions): http.Server {
	const verifier = new Verifier(opts.secret, opts.clockSkew, opts.oldSecret ?? null);
	const nowSec = opts.nowSec ?? (() => Math.floor(Date.now() / 1000));
	const seen: Seen = { hub: new Map(), match: new Map() };
	const routes = buildRoutes(store, opts.flags, () => (opts.nowSec ? opts.nowSec() : Date.now() / 1000), seen, opts.presence);
	const started = Date.now();
	let requests = 0;
	let rejected = 0;
	const byRoute: Record<string, number> = {};
	// how the game servers reach us: through Cloudflare (rofront.snick.co) or straight to the port
	const via = { cloudflare: 0, direct: 0 };
	let lastRejectLog = 0;
	const auth = new StatsAuth(opts.secret, opts.statsPassword ?? (() => null), () => (opts.nowSec ? opts.nowSec() : Date.now() / 1000));
	const LOGIN_MAX_BODY = 4096;

	// the live stats page: open event streams, told after lobby writes (at most once a second)
	const MAX_STREAMS = 200;
	const streams = new Set<http.ServerResponse>();
	const clock = (): number => (opts.nowSec ? opts.nowSec() : Date.now() / 1000);
	const statsBody = (): string => {
		const live = store.liveNow();
		const p = opts.presence ? opts.presence.totals() : null;
		return JSON.stringify({
			...buildStats(store.starts, clock()),
			now: { ...live, solo: p ? p.solo : 0, soloEasy: p ? p.soloEasy : 0, soloMedium: p ? p.soloMedium : 0, soloHard: p ? p.soloHard : 0, title: p ? p.title : 0, hubs: p ? p.hubs : 0 },
			players24h: opts.presence ? opts.presence.series(24, 96) : [],
		});
	};
	let pushTimer: NodeJS.Timeout | null = null;
	let lastPush = 0;
	const push = (): void => {
		pushTimer = null;
		lastPush = Date.now();
		if (streams.size === 0) return;
		const frame = `data: ${statsBody()}\n\n`;
		for (const s of streams) s.write(frame);
	};
	const schedulePush = (): void => {
		if (pushTimer || streams.size === 0) return;
		pushTimer = setTimeout(push, Math.max(0, 1000 - (Date.now() - lastPush)));
	};
	store.onChange = schedulePush;
	// a fresh frame every 5 s, which also keeps proxies and phones from closing an idle stream
	const beat = setInterval(() => {
		if (streams.size > 0) push();
	}, 5_000);
	beat.unref();

	const liveCount = (m: Map<string, number>): number => {
		const cutoff = nowSec() - 30;
		let n = 0;
		for (const [k, t] of m) {
			if (t >= cutoff) n++;
			else m.delete(k);
		}
		return n;
	};

	return http.createServer((req, res) => {
		let url = "/";
		try {
			url = new URL(req.url ?? "/", "http://lobbies.invalid").pathname;
		} catch {
			url = "/";
		}
		const html = (status: number, body: string, extra: Record<string, string> = {}): void => {
			res.writeHead(status, {
				"Content-Type": "text/html; charset=utf-8",
				"Content-Length": Buffer.byteLength(body),
				"Cache-Control": "no-store",
				"X-Frame-Options": "DENY",
				"Referrer-Policy": "no-referrer",
				...extra,
			});
			res.end(body);
		};
		const redirect = (status: number, to: string, extra: Record<string, string> = {}): void => {
			res.writeHead(status, { Location: to, "Cache-Control": "no-store", ...extra });
			res.end();
		};
		if (req.method === "GET" && url === "/") {
			redirect(302, "/stats");
			return;
		}
		// the login (statsAuth)
		if (url === "/login" && req.method === "GET") {
			const next = safeNext(new URL(req.url ?? "/", "http://lobbies.invalid").searchParams.get("next"));
			if (auth.check(req.headers.cookie)) {
				redirect(302, next);
				return;
			}
			html(auth.configured() ? 200 : 503, loginPage(next, auth.configured() ? null : "Sign-in is not set up yet."));
			return;
		}
		if (url === "/login" && req.method === "POST") {
			const chunks: Buffer[] = [];
			let size = 0;
			req.on("data", (c: Buffer) => {
				size += c.length;
				if (size <= LOGIN_MAX_BODY) chunks.push(c);
			});
			req.on("end", () => {
				if (size > LOGIN_MAX_BODY) {
					html(413, loginPage("/stats", "That was too long."));
					return;
				}
				const form = new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
				const next = safeNext(form.get("next"));
				const ip = clientIp(req);
				const r = auth.attempt(ip, form.get("password") ?? "");
				if (r === "ok") {
					opts.log("info", `stats sign-in from ${ip}`);
					redirect(303, next, { "Set-Cookie": cookieHeader(auth.issue() ?? "", COOKIE_DAYS * 86400) });
				} else if (r === "throttled") {
					opts.log("warn", `stats sign-in throttled for ${ip}`);
					html(429, loginPage(next, "Too many tries. Wait a while and try again."), { "Retry-After": "900" });
				} else if (r === "unconfigured") {
					html(503, loginPage(next, "Sign-in is not set up yet."));
				} else {
					opts.log("warn", `stats sign-in failed from ${ip}`);
					html(401, loginPage(next, "Wrong password."));
				}
			});
			req.on("error", () => {});
			return;
		}
		if (req.method === "GET" && url === "/logout") {
			redirect(303, "/login", { "Set-Cookie": cookieHeader("", 0) });
			return;
		}
		const isStats = url === "/stats" || url === "/stats/" || url === "/stats.json" || url === "/stats/stats.json" || url === "/stats/events" || url === "/stats.events";
		if (req.method === "GET" && isStats && !auth.check(req.headers.cookie)) {
			if (url === "/stats" || url === "/stats/") {
				redirect(302, `/login?next=${encodeURIComponent("/stats")}`);
			} else {
				res.writeHead(401, { "Content-Type": "application/json", "Cache-Control": "no-store" });
				res.end('{"ok":false,"err":"sign in at /login"}');
			}
			return;
		}
		// humans per public match (signed-in, aggregated only: no ids, codes or names)
		if (req.method === "GET" && (url === "/stats" || url === "/stats/")) {
			html(200, STATS_PAGE);
			return;
		}
		if (req.method === "GET" && (url === "/stats.json" || url === "/stats/stats.json")) {
			const body = statsBody();
			res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body), "Cache-Control": "no-cache" });
			res.end(body);
			return;
		}
		// the live page: Server-Sent Events, the stats on connect and after every change (≤ 1/s)
		if (req.method === "GET" && (url === "/stats/events" || url === "/stats.events")) {
			if (streams.size >= MAX_STREAMS) {
				res.writeHead(503, { "Content-Type": "text/plain", "Retry-After": "30" });
				res.end("too many viewers");
				return;
			}
			res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive", "X-Accel-Buffering": "no" });
			res.write(`retry: 3000\ndata: ${statsBody()}\n\n`);
			streams.add(res);
			req.on("close", () => streams.delete(res));
			return;
		}
		if (req.method === "GET" && url === "/health") {
			// in full to this box, a signed-in browser or a signed request; {ok:true} to anyone else
			const full =
				((opts.localHealth ?? true) && isLoopback(req.socket.remoteAddress)) ||
				auth.check(req.headers.cookie) ||
				(req.headers["x-tm-sig"] !== undefined && verifier.verify(req.headers, "GET", "/health", "", nowSec()).ok);
			if (!full) {
				res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
				res.end('{"ok":true}');
				return;
			}
			const body = JSON.stringify({
				ok: true,
				service: "rofront-lobbies",
				uptime: Math.round((Date.now() - started) / 1000),
				enabled: opts.flags().enabled,
				requests,
				rejected,
				hubs: liveCount(seen.hub),
				matchServers: liveCount(seen.match),
				...store.counts(),
				counters: store.counters,
				byRoute,
				via,
			});
			res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
			res.end(body);
			return;
		}
		if (req.method !== "POST" || !routes[url]) {
			res.writeHead(404, { "Content-Type": "application/json" });
			res.end('{"ok":false,"err":"not found"}');
			return;
		}
		const chunks: Buffer[] = [];
		let size = 0;
		let aborted = false;
		req.on("data", (c: Buffer) => {
			size += c.length;
			if (size > MAX_BODY && !aborted) {
				aborted = true;
				res.writeHead(413, { "Content-Type": "application/json", Connection: "close" });
				res.end('{"ok":false,"err":"too large"}');
				req.destroy();
				return;
			}
			if (!aborted) chunks.push(c);
		});
		req.on("end", () => {
			if (aborted) return;
			requests++;
			byRoute[url] = (byRoute[url] ?? 0) + 1;
			if (viaCloudflare(req)) via.cloudflare++;
			else via.direct++;
			const raw = Buffer.concat(chunks).toString("utf8");
			const verdict = verifier.verify(req.headers, "POST", url, raw, nowSec());
			if (!verdict.ok) {
				rejected++;
				const t = Date.now();
				if (t - lastRejectLog > 2000) {
					lastRejectLog = t;
					opts.log("warn", `rejected ${url} from ${clientIp(req)}: ${verdict.error}`);
				}
				// failed auth: no signature on the reply. A correctly signed request whose clock is off
				// learns the time (game servers' clocks can be minutes out), nothing else.
				const reply: Record<string, unknown> = { ok: false, err: "unauthorized" };
				if (verdict.error === "stale timestamp") reply.serverTime = nowSec();
				res.writeHead(verdict.status, { "Content-Type": "application/json" });
				res.end(JSON.stringify(reply));
				return;
			}
			let status = 200;
			let payload: unknown;
			try {
				const body = obj(JSON.parse(raw || "{}"), "body");
				if (body.protocol !== undefined && body.protocol !== PROTOCOL) throw new Invalid(`protocol ${String(body.protocol)} not supported (want ${PROTOCOL})`);
				const jobId = str(body.jobId ?? "ops", "jobId", 64, JOB_RE);
				payload = routes[url](body, jobId);
			} catch (e) {
				if (e instanceof Invalid || e instanceof SyntaxError) {
					status = 400;
					payload = { ok: false, err: e.message };
					opts.log("warn", `bad request ${url}: ${e.message}`);
				} else {
					status = 500;
					payload = { ok: false, err: "internal error" };
					opts.log("warn", `error in ${url}: ${(e as Error).stack ?? String(e)}`);
				}
			}
			const body = payload instanceof RawJson ? payload.json : JSON.stringify(payload);
			res.writeHead(status, {
				"Content-Type": "application/json",
				"Content-Length": Buffer.byteLength(body),
				"X-TM-Sig": signResponse(verdict.secret, verdict.nonce, status, body),
			});
			res.end(body);
		});
		req.on("error", () => {
			aborted = true;
		});
	});
}
