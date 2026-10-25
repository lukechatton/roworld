// The login in front of the human-facing pages (/stats, /stats.json, /stats/events, the full /health):
// docs/lobby-service.md "Stats login". Added 2026-10-12, with the move to https://rofront.snick.co, so the
// pages are not open to anyone.
//
// - One password, STATS_PASSWORD in ~/rofront-lobbies/.env (chmod 600), read again every few seconds:
//   changing it there signs everyone out, no restart.
// - A right password gets a cookie for COOKIE_DAYS: "<expiry>.<hex HMAC>", keyed by the service secret
//   and the password. HttpOnly, Secure, SameSite=Lax.
// - Compared in constant time (HMACs of both, timingSafeEqual).
// - Failed logins are throttled: FAIL_MAX per client per FAIL_WINDOW_S, GLOBAL_FAIL_MAX a minute in all.
//   Behind Cloudflare the client is CF-Connecting-IP, trusted only on a request that came through the
//   proxy (a private or loopback peer): straight to the port anyone can write that header.
import * as crypto from "crypto";
import type * as http from "http";

export const COOKIE = "rl_stats";
export const COOKIE_DAYS = 30;
export const FAIL_MAX = 5;
export const FAIL_WINDOW_S = 15 * 60;
export const GLOBAL_FAIL_MAX = 60;
// (any non-empty password: a short one is in use, 2026-10-12)
const MIN_PASSWORD = 1;

export type LoginResult = "ok" | "wrong" | "throttled" | "unconfigured";

const PRIVATE_RE = /^(?:::ffff:)?(?:127\.|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)|^::1$/;

/** Whether a peer address is this box or the docker bridge (a proxy hop: Caddy). */
export function isPrivate(addr: string | undefined): boolean {
	return typeof addr === "string" && PRIVATE_RE.test(addr);
}

/** Whether a peer address is this box itself. */
export function isLoopback(addr: string | undefined): boolean {
	return typeof addr === "string" && /^(?:::ffff:)?127\.|^::1$/.test(addr);
}

const IP_RE = /^[0-9A-Fa-f:.]{2,45}$/;

/** The client: CF-Connecting-IP when the request came through the proxy, else the peer. */
export function clientIp(req: http.IncomingMessage): string {
	const peer = req.socket.remoteAddress ?? "?";
	if (isPrivate(peer)) {
		const cf = req.headers["cf-connecting-ip"];
		const v = Array.isArray(cf) ? cf[0] : cf;
		if (typeof v === "string" && IP_RE.test(v.trim())) return v.trim();
	}
	return peer;
}

/** Whether the request came through Cloudflare (the proxy hop and its header). */
export function viaCloudflare(req: http.IncomingMessage): boolean {
	return isPrivate(req.socket.remoteAddress) && typeof req.headers["cf-connecting-ip"] === "string";
}

export function parseCookies(header: string | undefined): Record<string, string> {
	const out: Record<string, string> = {};
	if (!header) return out;
	for (const part of header.split(";")) {
		const eq = part.indexOf("=");
		if (eq <= 0) continue;
		out[part.slice(0, eq).trim()] = part.slice(eq + 1).trim();
	}
	return out;
}

export class StatsAuth {
	private fails = new Map<string, { n: number; since: number }>();
	private global = { n: 0, since: 0 };

	constructor(
		private readonly secret: string,
		private readonly password: () => string | null,
		private readonly now: () => number = () => Date.now() / 1000,
	) {}

	private pw(): string | null {
		const p = this.password();
		return typeof p === "string" && p.length >= MIN_PASSWORD ? p : null;
	}

	configured(): boolean {
		return this.pw() !== null;
	}

	private sign(pw: string, exp: number): string {
		const key = crypto.createHmac("sha256", this.secret).update(`stats-cookie\n${pw}`).digest();
		return crypto.createHmac("sha256", key).update(`v1\n${exp}`).digest("hex");
	}

	/** A cookie value good for COOKIE_DAYS (null: no password set). */
	issue(): string | null {
		const pw = this.pw();
		if (pw === null) return null;
		const exp = Math.floor(this.now()) + COOKIE_DAYS * 86400;
		return `${exp}.${this.sign(pw, exp)}`;
	}

	/** Whether the request carries a valid cookie. */
	check(cookieHeader: string | undefined): boolean {
		const pw = this.pw();
		if (pw === null) return false;
		const v = parseCookies(cookieHeader)[COOKIE];
		if (!v) return false;
		const m = /^(\d{9,11})\.([0-9a-f]{64})$/.exec(v);
		if (!m) return false;
		const exp = Number(m[1]);
		if (exp <= this.now()) return false;
		const want = Buffer.from(this.sign(pw, exp), "utf8");
		const got = Buffer.from(m[2], "utf8");
		return want.length === got.length && crypto.timingSafeEqual(want, got);
	}

	private throttled(ip: string, now: number): boolean {
		if (now - this.global.since >= 60) this.global = { n: 0, since: now };
		if (this.global.n >= GLOBAL_FAIL_MAX) return true;
		const f = this.fails.get(ip);
		return f !== undefined && now - f.since < FAIL_WINDOW_S && f.n >= FAIL_MAX;
	}

	private fail(ip: string, now: number): void {
		this.global.n++;
		const f = this.fails.get(ip);
		if (f === undefined || now - f.since >= FAIL_WINDOW_S) this.fails.set(ip, { n: 1, since: now });
		else f.n++;
		if (this.fails.size > 10_000) {
			for (const [k, v] of this.fails) if (now - v.since >= FAIL_WINDOW_S) this.fails.delete(k);
			if (this.fails.size > 10_000) this.fails.clear();
		}
	}

	/** A login attempt from `ip`. */
	attempt(ip: string, given: string): LoginResult {
		const pw = this.pw();
		if (pw === null) return "unconfigured";
		const now = this.now();
		if (this.throttled(ip, now)) return "throttled";
		const a = crypto.createHmac("sha256", this.secret).update(`stats-login\n${given}`).digest();
		const b = crypto.createHmac("sha256", this.secret).update(`stats-login\n${pw}`).digest();
		if (crypto.timingSafeEqual(a, b)) {
			this.fails.delete(ip);
			return "ok";
		}
		this.fail(ip, now);
		return "wrong";
	}
}

/** Only a path on this site's stats pages (no open redirect). */
export function safeNext(v: unknown): string {
	if (typeof v !== "string") return "/stats";
	return /^\/stats(?:[/.?#][^\s\\]*)?$/.test(v) && !v.startsWith("//") ? v : "/stats";
}

export function cookieHeader(value: string, maxAge: number): string {
	return `${COOKIE}=${value}; Max-Age=${maxAge}; Path=/; HttpOnly; Secure; SameSite=Lax`;
}

function esc(s: string): string {
	return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

/** The login page (the stats page's look). */
export function loginPage(next: string, message: string | null): string {
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Rofront live · sign in</title>
<style>
:root { --bg: #0e1116; --panel: #161b22; --line: #262d36; --text: #e6edf3; --dim: #8b949e; --accent: #f5a524; --bad: #f85149; }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--text); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; padding: 16px; }
form { width: 100%; max-width: 340px; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 22px 20px; display: grid; gap: 12px; }
h1 { font-size: 18px; margin: 0; }
p { margin: 0; color: var(--dim); }
label { font-size: 12px; color: var(--dim); text-transform: uppercase; letter-spacing: .06em; }
input { width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid var(--line); background: var(--bg); color: var(--text); font-size: 15px; }
input:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
button { padding: 10px 12px; border: 0; border-radius: 8px; background: var(--accent); color: #1a1200; font-weight: 700; font-size: 15px; cursor: pointer; }
.msg { color: var(--bad); }
</style>
</head>
<body>
<form method="post" action="/login">
<h1>Rofront live</h1>
<p>Sign in to see the live stats.</p>
${message ? `<p class="msg" role="alert">${esc(message)}</p>` : ""}
<label for="pw">Password</label>
<input id="pw" name="password" type="password" autocomplete="current-password" required autofocus>
<input type="hidden" name="next" value="${esc(next)}">
<button type="submit">Sign in</button>
</form>
</body>
</html>
`;
}
