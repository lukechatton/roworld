// Signed client (tests and ops scripts). Same wire format as the Luau client
// (src/server/Lobbies/LobbyHttp.luau).
import * as crypto from "crypto";
import * as http from "http";
import { signRequest, signResponse, safeEqualHex } from "./auth";

export class LobbyClient {
	constructor(
		private readonly baseUrl: string,
		private readonly secret: string,
		private readonly nowSec: () => number = () => Math.floor(Date.now() / 1000),
	) {}

	async post<T = Record<string, unknown>>(path: string, body: Record<string, unknown>): Promise<{ status: number; body: T; verified: boolean }> {
		const raw = JSON.stringify({ protocol: 1, ...body });
		const ts = String(this.nowSec());
		const nonce = crypto.randomBytes(16).toString("hex");
		const sig = signRequest(this.secret, ts, nonce, "POST", path, raw);
		const url = new URL(path, this.baseUrl);
		return new Promise((resolve, reject) => {
			const req = http.request(
				url,
				{
					method: "POST",
					headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(raw), "X-TM-Ts": ts, "X-TM-Nonce": nonce, "X-TM-Sig": sig },
					timeout: 8000,
				},
				(res) => {
					const chunks: Buffer[] = [];
					res.on("data", (c: Buffer) => chunks.push(c));
					res.on("end", () => {
						const text = Buffer.concat(chunks).toString("utf8");
						const got = String(res.headers["x-tm-sig"] ?? "");
						const want = signResponse(this.secret, nonce, res.statusCode ?? 0, text);
						let parsed: T;
						try {
							parsed = JSON.parse(text) as T;
						} catch {
							parsed = {} as T;
						}
						resolve({ status: res.statusCode ?? 0, body: parsed, verified: safeEqualHex(got, want) });
					});
				},
			);
			req.on("timeout", () => req.destroy(new Error("timeout")));
			req.on("error", reject);
			req.end(raw);
		});
	}
}
