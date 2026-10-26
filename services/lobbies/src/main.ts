// Entry point (pm2 app "rofront-lobbies"). docs/lobby-service.md "Ops".
import * as fs from "fs";
import * as path from "path";
import { envReader, loadConfig, readEnabled } from "./config";
import { Presence, type Sample } from "./presence";
import { createServer } from "./server";
import { LobbyStore } from "./store";

const dir = process.env.RL_DIR ?? process.cwd();
const config = loadConfig(dir);
const LEVELS = { debug: 0, info: 1, warn: 2 } as const;
const log = (level: "debug" | "info" | "warn", msg: string): void => {
	if (LEVELS[level] < LEVELS[config.logLevel]) return;
	const line = `${new Date().toISOString()} ${level.toUpperCase().padEnd(5)} ${msg}`;
	if (level === "warn") console.error(line);
	else console.log(line);
};

const store = new LobbyStore(() => Date.now() / 1000);
if (config.stateFile && fs.existsSync(config.stateFile)) {
	try {
		const n = store.restore(JSON.parse(fs.readFileSync(config.stateFile, "utf8")));
		log("info", `restored ${n} lobby record(s) from ${config.stateFile}`);
	} catch (e) {
		log("warn", `could not restore ${config.stateFile}: ${(e as Error).message}`);
	}
}

// match starts (humans per public match): one JSON line each, kept 30 days (docs "Stats")
const startsFile = config.stateFile ? path.join(dir, "starts.jsonl") : null;
if (startsFile && fs.existsSync(startsFile)) {
	try {
		const lines = fs.readFileSync(startsFile, "utf8").split("\n");
		const list = [];
		for (const line of lines) {
			if (!line.trim()) continue;
			try {
				list.push(JSON.parse(line));
			} catch {
				// a torn last line (a crash mid-write): skip it
			}
		}
		store.loadStarts(list);
		if (list.length > store.starts.length + 1000) {
			// drop what aged out
			fs.writeFileSync(startsFile, store.starts.map((m) => JSON.stringify(m)).join("\n") + "\n", { mode: 0o600 });
		}
		log("info", `loaded ${store.starts.length} match start(s) from ${startsFile}`);
	} catch (e) {
		log("warn", `could not read ${startsFile}: ${(e as Error).message}`);
	}
}
store.onStart = (m) => {
	log("info", `match started on ${m.map}: ${m.humans} human(s) of ${m.max}`);
	if (!startsFile) return;
	try {
		fs.appendFileSync(startsFile, JSON.stringify(m) + "\n", { mode: 0o600 });
	} catch (e) {
		log("warn", `could not append to ${startsFile}: ${(e as Error).message}`);
	}
};

// who is playing what (solo / title from hubs, public from the lobby records): a sample a minute in
// presence.jsonl, kept 30 days (docs "Stats")
const presence = new Presence(() => Date.now() / 1000);
const presenceFile = config.stateFile ? path.join(dir, "presence.jsonl") : null;
if (presenceFile && fs.existsSync(presenceFile)) {
	try {
		const list: Sample[] = [];
		for (const line of fs.readFileSync(presenceFile, "utf8").split("\n")) {
			if (!line.trim()) continue;
			try {
				list.push(JSON.parse(line));
			} catch {
				// a torn last line
			}
		}
		presence.loadSamples(list);
		if (list.length > presence.samples.length + 1000) {
			fs.writeFileSync(presenceFile, presence.samples.map((m) => JSON.stringify(m)).join("\n") + "\n", { mode: 0o600 });
		}
	} catch (e) {
		log("warn", `could not read ${presenceFile}: ${(e as Error).message}`);
	}
}
presence.onSample = (smp) => {
	if (!presenceFile) return;
	try {
		fs.appendFileSync(presenceFile, JSON.stringify(smp) + "\n", { mode: 0o600 });
	} catch (e) {
		log("warn", `could not append to ${presenceFile}: ${(e as Error).message}`);
	}
};
const sampler = setInterval(() => {
	const live = store.liveNow();
	presence.sample(live.waiting, live.playing);
}, 60_000);

function saveState(): void {
	if (!config.stateFile || !store.dirty) return;
	store.dirty = false;
	const tmp = `${config.stateFile}.tmp`;
	try {
		fs.writeFileSync(tmp, JSON.stringify(store.snapshot()), { mode: 0o600 });
		fs.renameSync(tmp, config.stateFile);
	} catch (e) {
		log("warn", `state save failed: ${(e as Error).message}`);
	}
}

let enabled = config.enabled;
const flagTimer = setInterval(() => {
	const next = readEnabled(dir, enabled);
	if (next !== enabled) {
		enabled = next;
		log("info", `LOBBIES switched ${enabled ? "ON" : "off"}`);
	}
}, 2000);

// the stats pages' password (STATS_PASSWORD in .env, read again every 5 s; unset: the pages stay locked)
const statsPassword = envReader(dir, "STATS_PASSWORD");
if (config.oldSecret) log("info", `rotation: the previous secret is accepted until ${new Date(config.oldSecret.until * 1000).toISOString()}`);
const server = createServer(store, { secret: config.secret, oldSecret: config.oldSecret, clockSkew: config.clockSkew, flags: () => ({ enabled }), log, presence, statsPassword });
server.keepAliveTimeout = 65_000;
server.headersTimeout = 70_000;
server.requestTimeout = 15_000;
server.on("error", (e) => {
	// e.g. the port is taken: exit so pm2 restarts us (a process without its listener serves nobody)
	log("warn", `server error: ${(e as Error).message}`);
	process.exit(1);
});
server.listen(config.port, config.host, () => {
	log("info", `rofront-lobbies listening on ${config.host}:${config.port} (lobbies ${enabled ? "ON" : "off"})`);
});

let lastCounts = "";
const saver = setInterval(saveState, 2000);
const sweeper = setInterval(() => {
	store.sweep();
	const c = JSON.stringify(store.counts());
	if (c !== lastCounts) {
		lastCounts = c;
		log("debug", `store ${c}`);
	}
}, 10_000);

function shutdown(signal: string): void {
	log("info", `${signal}: saving state and exiting`);
	clearInterval(saver);
	clearInterval(sweeper);
	clearInterval(flagTimer);
	clearInterval(sampler);
	store.dirty = true;
	saveState();
	server.close(() => process.exit(0));
	setTimeout(() => process.exit(0), 2000).unref();
}
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("uncaughtException", (e) => log("warn", `uncaught: ${e.stack ?? String(e)}`));
