// pm2 config for ONE app: "rofront-lobbies" (easy-1 is shared: never touch other apps).
module.exports = {
	apps: [
		{
			name: "rofront-lobbies",
			script: "dist/src/main.js",
			cwd: __dirname,
			exec_mode: "fork",
			instances: 1,
			// (300M restarted it every ~40 s at 10k players: its working set there is ~370 MB, 2026-10-11)
			max_memory_restart: "1500M",
			kill_timeout: 3000,
			restart_delay: 2000,
			env: { RL_DIR: __dirname, NODE_ENV: "production" },
		},
	],
};
