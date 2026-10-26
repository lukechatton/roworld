// Request/response signing (docs/lobby-service.md "Auth").
//
// Request headers:  X-TM-Ts (unix seconds), X-TM-Nonce (16..64 [0-9a-zA-Z-]), X-TM-Sig
//   sig = hex(HMAC-SHA256(secret, "v1\n" + ts + "\n" + nonce + "\n" + METHOD + "\n" + path + "\n" + body))
// Response header:  X-TM-Sig = hex(HMAC-SHA256(secret, "v1r\n" + requestNonce + "\n" + status + "\n" + body))
// A request is accepted once: |now - ts| <= skew and the nonce hasn't been seen in the last 2 * skew s.
// The response signature binds the reply to the request's nonce, so a replayed/forged reply fails.
import * as crypto from "crypto";

export function hmacHex(secret: string, message: string): string {
	return crypto.createHmac("sha256", secret).update(message, "utf8").digest("hex");
}

export function requestString(ts: string, nonce: string, method: string, path: string, body: string): string {
	return `v1\n${ts}\n${nonce}\n${method.toUpperCase()}\n${path}\n${body}`;
}

export function responseString(nonce: string, status: number, body: string): string {
	return `v1r\n${nonce}\n${status}\n${body}`;
}

export function signRequest(secret: string, ts: string, nonce: string, method: string, path: string, body: string): string {
	return hmacHex(secret, requestString(ts, nonce, method, path, body));
}

export function signResponse(secret: string, nonce: string, status: number, body: string): string {
	return hmacHex(secret, responseString(nonce, status, body));
}

export function safeEqualHex(a: string, b: string): boolean {
	if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
	return crypto.timingSafeEqual(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

const NONCE_RE = /^[0-9A-Za-z-]{16,64}$/;
const TS_RE = /^\d{9,11}$/;
const SIG_RE = /^[0-9a-f]{64}$/;

/** The previous secret during a rotation (RL_SECRET_OLD): still accepted until `until` (unix s). */
export interface OldSecret {
	secret: string;
	until: number;
}

// `secret` is the one the request was signed with: the reply is signed with it too, so a game server
// still on the old secret can check it.
export type VerifyResult = { ok: true; nonce: string; secret: string } | { ok: false; status: number; error: string; nonce?: string };

export class NonceCache {
	private seen = new Map<string, number>(); // nonce -> expiry (unix s)
	private lastSweep = 0;
	constructor(private readonly ttl: number, private readonly max = 500_000) {}

	// true if new (and remembers it), false if replayed / cache full
	add(nonce: string, now: number): boolean {
		if (now - this.lastSweep >= 5) this.sweep(now);
		const exp = this.seen.get(nonce);
		if (exp !== undefined && exp > now) return false;
		if (this.seen.size >= this.max) return false;
		this.seen.set(nonce, now + this.ttl);
		return true;
	}

	sweep(now: number): void {
		this.lastSweep = now;
		for (const [n, exp] of this.seen) if (exp <= now) this.seen.delete(n);
	}

	get size(): number {
		return this.seen.size;
	}
}

export class Verifier {
	readonly nonces: NonceCache;
	constructor(private readonly secret: string, private readonly skew: number, private readonly old: OldSecret | null = null) {
		this.nonces = new NonceCache(skew * 2 + 5);
	}

	verify(headers: Record<string, string | string[] | undefined>, method: string, path: string, body: string, nowSec: number): VerifyResult {
		const h = (k: string): string => {
			const v = headers[k.toLowerCase()];
			return Array.isArray(v) ? v[0] ?? "" : v ?? "";
		};
		const ts = h("x-tm-ts");
		const nonce = h("x-tm-nonce");
		const sig = h("x-tm-sig").toLowerCase();
		if (!NONCE_RE.test(nonce)) return { ok: false, status: 401, error: "bad nonce" };
		if (!TS_RE.test(ts) || !SIG_RE.test(sig)) return { ok: false, status: 401, error: "bad auth headers", nonce };
		let secret = this.secret;
		if (!safeEqualHex(signRequest(secret, ts, nonce, method, path, body), sig)) {
			const old = this.old;
			if (old === null || nowSec >= old.until || !safeEqualHex(signRequest(old.secret, ts, nonce, method, path, body), sig)) {
				return { ok: false, status: 401, error: "bad signature", nonce };
			}
			secret = old.secret;
		}
		if (Math.abs(nowSec - Number(ts)) > this.skew) return { ok: false, status: 401, error: "stale timestamp", nonce };
		if (!this.nonces.add(nonce, nowSec)) return { ok: false, status: 401, error: "replayed nonce", nonce };
		return { ok: true, nonce, secret };
	}
}
