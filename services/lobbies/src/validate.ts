// Strict input validation for request bodies (everything from the network is untrusted, even when
// signed: a bug in a game server must not corrupt the store).
export class Invalid extends Error {}

export function obj(v: unknown, what: string): Record<string, unknown> {
	if (!v || typeof v !== "object" || Array.isArray(v)) throw new Invalid(`${what}: object expected`);
	return v as Record<string, unknown>;
}

export function str(v: unknown, what: string, max: number, re?: RegExp): string {
	if (typeof v !== "string" || v.length === 0 || v.length > max) throw new Invalid(`${what}: string (1..${max}) expected`);
	if (re && !re.test(v)) throw new Invalid(`${what}: bad format`);
	return v;
}

export function optStr(v: unknown, what: string, max: number, re?: RegExp): string | null {
	if (v === undefined || v === null || v === false || v === "") return null;
	return str(v, what, max, re);
}

export function int(v: unknown, what: string, lo: number, hi: number): number {
	if (typeof v !== "number" || !Number.isFinite(v) || Math.floor(v) !== v || v < lo || v > hi) throw new Invalid(`${what}: integer ${lo}..${hi} expected`);
	return v;
}

export function num(v: unknown, what: string, lo: number, hi: number): number {
	if (typeof v !== "number" || !Number.isFinite(v) || v < lo || v > hi) throw new Invalid(`${what}: number ${lo}..${hi} expected`);
	return v;
}

export function arr<T>(v: unknown, what: string, max: number, each: (x: unknown, i: number) => T): T[] {
	// Roblox's JSONEncode writes an empty table as [] (and never as {}), but accept {} as empty too
	if (v && typeof v === "object" && !Array.isArray(v) && Object.keys(v as object).length === 0) return [];
	if (!Array.isArray(v) || v.length > max) throw new Invalid(`${what}: array (≤ ${max}) expected`);
	return v.map((x, i) => each(x, i));
}

export function opaque(v: unknown, what: string, maxJson: number): unknown {
	if (v === undefined) return null;
	const s = JSON.stringify(v);
	if (s === undefined || s.length > maxJson) throw new Invalid(`${what}: too large`);
	return JSON.parse(s);
}

export const ID_RE = /^[0-9A-Za-z_-]{1,64}$/;
export const JOB_RE = /^[0-9A-Za-z_-]{1,64}$/; // game.JobId (GUID) or a test id
export const USER_MAX = 1e13;
