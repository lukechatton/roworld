// Service configuration: .env file (KEY=VALUE lines) + environment, with defaults.
// The secret is never logged. docs/lobby-service.md "Ops".
import * as fs from "fs";
import * as path from "path";
import { OldSecret } from "./auth";

export interface Config {
	port: number;
	host: string;
	secret: string;
	// a rotation: RL_SECRET_OLD is accepted too until RL_SECRET_OLD_UNTIL (unix s); either unset: off
	oldSecret: OldSecret | null;
	enabled: boolean; // LOBBIES=0: hubs go back to MemoryStore within one list (3 s), no publish
	clockSkew: number; // s: accepted |now - X-TM-Ts|
	stateFile: string | null; // snapshot of the store (survives a restart)
	logLevel: "debug" | "info" | "warn";
}

export function parseEnvFile(text: string): Record<string, string> {
	const out: Record<string, string> = {};
	for (const raw of text.split(/\r?\n/)) {
		const line = raw.trim();
		if (!line || line.startsWith("#")) continue;
		const eq = line.indexOf("=");
		if (eq <= 0) continue;
		let value = line.slice(eq + 1).trim();
		if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
		out[line.slice(0, eq).trim()] = value;
	}
	return out;
}

function num(v: string | undefined, dflt: number): number {
	if (v === undefined || v === "") return dflt;
	const n = Number(v);
	return Number.isFinite(n) ? n : dflt;
}

function bool(v: string | undefined, dflt: boolean): boolean {
	if (v === undefined || v === "") return dflt;
	return v === "1" || v.toLowerCase() === "true" || v.toLowerCase() === "yes";
}

export function envFile(dir: string): string {
	return path.join(dir, ".env");
}

export function loadConfig(dir: string = process.cwd(), env: NodeJS.ProcessEnv = process.env): Config {
	const file = envFile(dir);
	const fileVars = fs.existsSync(file) ? parseEnvFile(fs.readFileSync(file, "utf8")) : {};
	const get = (k: string): string | undefined => env[k] ?? fileVars[k];
	const secret = get("RL_SECRET") ?? "";
	if (secret.length < 32) throw new Error("RL_SECRET missing or shorter than 32 characters (.env)");
	const oldSecret = get("RL_SECRET_OLD") ?? "";
	const oldUntil = num(get("RL_SECRET_OLD_UNTIL"), 0);
	const level = get("LOG_LEVEL");
	return {
		port: num(get("PORT"), 3002),
		host: get("HOST") ?? "0.0.0.0",
		secret,
		oldSecret: oldSecret.length >= 32 && oldSecret !== secret && oldUntil > 0 ? { secret: oldSecret, until: oldUntil } : null,
		enabled: bool(get("LOBBIES"), true),
		clockSkew: num(get("CLOCK_SKEW"), 120),
		stateFile: get("STATE_FILE") === "off" ? null : path.join(dir, get("STATE_FILE") ?? "state.json"),
		logLevel: level === "debug" || level === "warn" ? level : "info",
	};
}

/** Re-read only the LOBBIES switch (the kill switch follows an .env edit without a restart). */
export function readEnabled(dir: string, fallback: boolean): boolean {
	try {
		const vars = parseEnvFile(fs.readFileSync(envFile(dir), "utf8"));
		return bool(process.env.LOBBIES ?? vars.LOBBIES, true);
	} catch {
		return fallback;
	}
}

/** A .env value read again at most every `everyMs` (the stats password changes without a restart);
 * null while it is unset or empty. */
export function envReader(dir: string, key: string, everyMs = 5000): () => string | null {
	let value: string | null = null;
	let at = -Infinity;
	return () => {
		const t = Date.now();
		if (t - at >= everyMs) {
			at = t;
			try {
				const v = process.env[key] ?? parseEnvFile(fs.readFileSync(envFile(dir), "utf8"))[key];
				value = typeof v === "string" && v.length > 0 ? v : null;
			} catch {
				// keep the last value
			}
		}
		return value;
	};
}
