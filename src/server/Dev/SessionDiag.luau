-- Session dev diagnostics (server). Active only when workspace attribute AF_DIAG == true. Commands via
-- the workspace attribute "af_srv_cmd"; result in "af_srv_result"; stats as af_srv_* attributes.
-- Fake participants are plain tables that behave like connected players: each runs a REAL client
-- Session + GameState (src/client/Session.luau, required from StarterPlayerScripts) fed with exactly
-- the snapshot / delta buffers a Roblox client gets, and sends encoded intents through it — so a 2+
-- player match (and a second full client mirror) can be exercised with a single Studio client.
-- `mirror` compares every fake's GameState grid with the server Sim's.
--   lobbies | fill <ffa|team> | free <ffa|team> <n> | noroom <secs> (Quick Play) | lobby <sec> | fake_join <name> | fake_spawn <name> | fake_expand <name> | fake_leave <name> |
--   fake_drop <name> (disconnect) | timelimit <ticks from now> | stats | mirror | settings |
--   eliminate (the real player falls to the biggest AI nation: the takeover offer)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Protocol = require(ReplicatedStorage.Airfront.Net.Protocol)

local Diag = {}
Diag.fakes = {} :: { [string]: any }

function Diag.is_fake(peer: any): boolean
	return type(peer) == "table" and peer.fake == true
end

--- ServerMain routes messages for fake peers here.
function Diag.deliver(peer: any, op: number, ...: any)
	if peer.handler then
		peer.handler(op, ...)
	end
	peer.messages += 1
	local args = table.pack(...)
	for i = 1, args.n do
		if type(args[i]) == "buffer" then
			peer.bytes += buffer.len(args[i])
		end
	end
	if op == Protocol.OP.SNAPSHOT then
		peer.owner = args[1]
		peer.snapshots += 1
		local ok, snap = pcall(Protocol.decode_snapshot, args[2])
		peer.last_snapshot_ok = ok
		if ok then
			peer.tick = snap.t
		end
	elseif op == Protocol.OP.DELTA then
		peer.deltas += 1
		local ok, d = pcall(Protocol.decode_delta, args[1], args[2])
		if ok then
			peer.tick = d.t or peer.tick
			for _, e in d.ev or {} do
				if e[1] == 19 then
					if e[2] ~= -1 and e[2] ~= peer.owner then
						peer.leaks += 1 -- someone else's private message
					end
					table.insert(peer.msgs, e[4])
					if #peer.msgs > 20 then
						table.remove(peer.msgs, 1)
					end
				end
			end
		else
			peer.decode_errors += 1
		end
	elseif op == Protocol.OP.MATCH_CLOSED then
		peer.closed = args[1]
	end
end

function Diag.start(ServerMain: any)
	local server = ServerMain.server
	local function fake(name: string)
		local f = Diag.fakes[name]
		if f == nil then
			f = {
				fake = true,
				name = name,
				owner = 0,
				bytes = 0,
				messages = 0,
				deltas = 0,
				snapshots = 0,
				tick = -1,
				leaks = 0,
				decode_errors = 0,
				msgs = {},
			}
			Diag.fakes[name] = f
			-- a real client Session wired to the server in-process
			local ok, SessionMod = pcall(function()
				return require(game:GetService("StarterPlayer").StarterPlayerScripts.AirfrontClient.Session)
			end)
			if ok then
				local Core = ReplicatedStorage.Airfront.Core
				local who = { uid = "fake_" .. name, name = name }
				local ses = SessionMod.new({
					now = os.clock,
					mobile = false,
					display_name = function()
						return name
					end,
					require_core = function(n: string)
						local m = Core:FindFirstChild(n)
						return if m then require(m) else nil
					end,
					warn = warn,
					net = {
						connected = true,
						send = function(op: number, ...: any)
							if op ~= Protocol.OP.HELLO and op ~= Protocol.OP.SETTING then
								server:on_client(f, who, op, ...)
							end
						end,
						listen = function(fn)
							f.handler = fn
						end,
					},
				})
				ses.threaded = false
				-- code-fixer: does the state this fake starts from contain its own nation? (review #8)
				ses.joined_owner:Connect(function(id: number)
					local st = ses.state
					f.own_at_join = st ~= nil and st.owners[id] ~= nil and st:local_info() ~= nil
				end)
				ses.notice:Connect(function(text: string)
					f.last_notice = text
				end)
				f.session = ses
				f.handler(Protocol.OP.LOBBY, server:lobby_info(f))
			end
		end
		return f
	end
	local function run(cmd: string): string
		local w = string.split(cmd, " ")
		local op = w[1]
		if op == "noroom" then
			-- Quick Play tests: every seat request finds no room for <secs> (the line, CANCEL)
			local dir = ServerMain.directory
			if dir == nil then
				return "not a hub"
			end
			local real = dir.deps.store
			local until_t = os.clock() + (tonumber(w[2]) or 10)
			dir.deps.store = setmetatable({
				take = function(spec: any): any
					if os.clock() < until_t then
						return nil
					end
					return real.take(spec)
				end,
			}, { __index = real })
			return "no room for " .. tostring(tonumber(w[2]) or 10) .. " s"
		elseif op == "lobbies" or op == "fill" or op == "free" then
			-- the public lobbies on this hub (Quick Play tests): list them; fill <ffa|team> marks every open
			-- lobby of the kind full; free <ffa|team> <n> frees n seats in the soonest one
			local dir, store = ServerMain.directory, ServerMain.lobby_store
			if dir == nil or store == nil then
				return "not a hub"
			end
			local LobbyRules = require(script.Parent.Parent.Lobbies.LobbyRules) :: any
			local now = os.time()
			if op ~= "lobbies" then
				local mode = w[2] or "ffa"
				local n = tonumber(w[3]) or 1
				local done = 0
				for _, l in dir:lobbies() do
					if l.status == "open" and LobbyRules.mode_of(l) == mode and l.starts > now + LobbyRules.JOIN_CLOSE_S then
						store.update(l.id, function(v: any): any?
							local d = LobbyRules.decode(v)
							if d == nil then
								return nil
							end
							d.players = if op == "fill" then d.max else math.max(0, d.max - n)
							return d
						end)
						done += 1
						if op == "free" then
							break
						end
					end
				end
				dir._refresh_in = 0 -- (the next tick lists again; a refresh of our own would race it)
				return ("%s %s: %d lobbies"):format(op, mode, done)
			end
			local parts = {}
			for _, l in dir:lobbies() do
				if l.status == "open" then
					table.insert(parts, ("%s %s %s %d/%d in %ds"):format(string.sub(l.id, 1, 6), LobbyRules.mode_of(l), l.map, l.players, l.max, l.starts - now))
				end
			end
			local d = dir.demand
			return ("open: %s | queue %d | demand ffa %.2f/s team %.2f/s"):format(
				table.concat(parts, "; "),
				dir:queue_size(),
				if d.ffa then d.ffa.rate else 0,
				if d.team then d.team.rate else 0
			)
		elseif op == "lobby" then
			server.lobby_countdown_sec = tonumber(w[2]) or 15
		elseif op == "fake_join" then
			local f = fake(w[2] or "Bot")
			server._last_join_msec[f] = nil
			if f.session then
				f.handler(Protocol.OP.LOBBY, server:lobby_info(f))
				f.session:join_multiplayer()
			else
				server:on_client(f, { uid = "fake_" .. f.name, name = f.name }, Protocol.OP.JOIN)
			end
			return ("joined %s owner=%d stage=%s"):format(f.name, f.owner, server:stage())
		elseif op == "mirror" then
			local sim = server:sim()
			if sim == nil then
				return "no match"
			end
			local grid = buffer.tostring(sim.owner)
			local parts = {}
			for name, f in Diag.fakes do
				local st = f.session and f.session.state
				if st and f.session.mode == 2 and st.local_owner ~= 0 then
					local me = st:get_owner(st.local_owner)
					table.insert(
						parts,
						("%s: tick %d/%d grid %s owner=%d tiles=%d phase=%d"):format(
							name,
							st.tick,
							sim.tick,
							if buffer.tostring(st.owner) == grid then "== sim" else "DIFFERS",
							st.local_owner,
							me and me.tiles or -1,
							st.phase
						)
					)
				else
					table.insert(
						parts,
						("%s: not in match (mode %s)"):format(name, tostring(f.session and f.session.mode))
					)
				end
			end
			return table.concat(parts, "\n")
		elseif op == "fake_spawn" or op == "fake_expand" then
			local f = fake(w[2] or "Bot")
			local sim = server:sim()
			if sim == nil or f.owner == 0 then
				return "not in a match"
			end
			local map = sim.map
			local target = -1
			if op == "fake_spawn" then
				local land = map.land_tiles
				for k = 1, 5000 do
					local t = land[1 + (k * 7919 + #f.name * 104729) % #land]
					if map:is_contestable(t) and buffer.readi32(sim.owner, t * 4) == 0 and not map:is_coastal(t) then
						target = t
						break
					end
				end
				server:on_client(
					f,
					{ uid = "fake_" .. f.name, name = f.name },
					Protocol.OP.INTENT,
					Protocol.encode_intent({ type = "spawn", tile = target })
				)
			else
				for _, t in map.land_tiles do
					if buffer.readi32(sim.owner, t * 4) == f.owner then
						for _, n in map:neighbors4(t) do
							if buffer.readi32(sim.owner, n * 4) == 0 and map:is_contestable(n) then
								target = n
								break
							end
						end
						if target >= 0 then
							break
						end
					end
				end
				server:on_client(
					f,
					{ uid = "fake_" .. f.name, name = f.name },
					Protocol.OP.INTENT,
					Protocol.encode_intent({ type = "attack", tile = target, ratio = 0.5 })
				)
			end
			return ("%s %s → tile %d"):format(op, f.name, target)
		elseif op == "fake_leave" then
			local f = fake(w[2] or "Bot")
			if f.session then
				f.session:leave_match()
			else
				server:on_client(f, { uid = "", name = "" }, Protocol.OP.LEAVE)
			end
		elseif op == "step_fault" then
			-- code-fixer: make the live match's Sim.step throw (review #6): "once", "always" or "off"
			local sim = server:sim()
			if sim == nil then
				return "no match"
			end
			local mode = w[2] or "once"
			local real = sim._diag_real_step or sim.step
			sim._diag_real_step = real
			if mode == "off" then
				sim.step = real
			else
				local armed = true
				sim.step = function(self2)
					if mode == "always" or armed then
						armed = false
						error("diag: injected Sim.step fault")
					end
					return real(self2)
				end
			end
			return "step_fault " .. mode
		elseif op == "active" then
			-- seconds since each participant was last seen at the controls (review #13)
			local parts = {}
			local now = os.clock() * 1000
			for _, peer in server._order do
				local part = server._participants[peer]
				table.insert(
					parts,
					("%s idle %.1f s owner=%d"):format(part.name, (now - part.active_msec) / 1000, part.owner)
				)
			end
			return table.concat(parts, "\n")
		elseif op == "eliminate" then
			-- takeover check: the real player's nation falls to the biggest AI nation
			local sim = server:sim()
			if sim == nil then
				return "no match"
			end
			for peer, part in server._participants do
				if not Diag.is_fake(peer) and part.owner ~= 0 then
					local best = 0
					for id = 1, sim.owner_total do
						if sim.o_kind[id] == 0 and sim.o_alive[id] == 1 and (best == 0 or sim.o_tiles[id] > sim.o_tiles[best]) then
							best = id
						end
					end
					sim.o_killer[part.owner] = best
					sim:_eliminate(part.owner, best)
					return ("eliminated %d by %d (%s)"):format(part.owner, best, tostring(sim.o_name[best]))
				end
			end
			return "no player"
		elseif op == "fake_drop" then
			server:peer_disconnected(fake(w[2] or "Bot"))
		elseif op == "timelimit" then
			local sim = server:sim()
			if sim == nil then
				return "no match"
			end
			sim.time_limit_ticks = sim.tick + (tonumber(w[2]) or 100)
			return "time limit at tick " .. sim.time_limit_ticks
		elseif op == "settings" then
			local SettingsStore = require(script.Parent.Parent.SettingsStore)
			local HttpService = game:GetService("HttpService")
			local parts = {}
			for _, pl in game:GetService("Players"):GetPlayers() do
				local data, loaded = SettingsStore.peek(pl)
				table.insert(
					parts,
					("%s loaded=%s %s"):format(pl.Name, tostring(loaded), HttpService:JSONEncode(data or {}))
				)
			end
			return table.concat(parts, "\n")
		elseif op == "stats" then
			local parts = {}
			for name, f in Diag.fakes do
				table.insert(
					parts,
					("%s owner=%d own_nation_at_join=%s notice=%s tick=%d deltas=%d snaps=%d bytes=%d leaks=%d decode_errors=%d closed=%s last_msg=%s"):format(
						name,
						f.owner,
						tostring(f.own_at_join),
						tostring(f.last_notice),
						f.tick,
						f.deltas,
						f.snapshots,
						f.bytes,
						f.leaks,
						f.decode_errors,
						tostring(f.closed),
						tostring(f.msgs[#f.msgs])
					)
				)
			end
			return table.concat(parts, "\n")
		else
			return "unknown " .. tostring(op)
		end
		return "ok " .. cmd
	end
	workspace:GetAttributeChangedSignal("af_srv_cmd"):Connect(function()
		local cmd = workspace:GetAttribute("af_srv_cmd")
		if type(cmd) ~= "string" or cmd == "" then
			return
		end
		workspace:SetAttribute("af_srv_cmd", "")
		local ok, res = pcall(run, cmd)
		workspace:SetAttribute("af_srv_result", if ok then res else "error: " .. tostring(res))
	end)
	-- Grid hash every 100 ticks (the real client publishes af_hash for the same ticks).
	local hashes = {}
	game:GetService("RunService").Heartbeat:Connect(function()
		local sim = server:sim()
		if sim and sim.tick % 100 == 0 and hashes[sim.tick] == nil then
			local b = sim.owner
			local h = 0
			for i = 0, 1024 * 512 - 1 do
				local v = buffer.readi32(b, i * 4)
				if v ~= 0 then
					h = (h + v * (i % 9973 + 1)) % 2147483647
				end
			end
			hashes[sim.tick] = h
			workspace:SetAttribute("af_srv_hash_" .. sim.tick, h)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			workspace:SetAttribute("af_srv_stage", server:stage())
			workspace:SetAttribute("af_srv_participants", server:participant_count())
			local sim = server:sim()
			workspace:SetAttribute("af_srv_tick", if sim then sim.tick else -1)
			local st = ServerMain.last_stats
			if st then
				workspace:SetAttribute(
					"af_srv_stats",
					("window %.0fs: step avg %.2f p99 %.2f max %.2f ms | encode %.2f ms | sent %.1f KB (%d deltas, max %d B) | snapshots %d (%d B, %.1f ms) | intents %d/%d dropped"):format(
						ServerMain.last_stats_window or 0,
						st.step_ms_avg,
						st.step_ms_p99,
						st.step_ms_max,
						st.encode_ms_avg,
						st.bytes_sent / 1024,
						st.deltas_sent,
						st.delta_bytes_max,
						st.snapshots_sent,
						st.snapshot_bytes,
						st.snapshot_ms or 0,
						st.intents_ok,
						st.intents_dropped
					)
				)
			end
		end
	end)
end

return Diag
