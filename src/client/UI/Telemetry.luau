--!nonstrict
-- Match milestones for the Creator Dashboard (src/server/Analytics.luau logs them with Roblox's
-- AnalyticsService). Solo matches run on this client, so the client reports for every match it plays:
-- started (mode, map), spawned, first attack, whole minutes alive, eliminated (by whom), the end (won
-- or lost, rank) or leaving early; plus the title screen, How to Play and Spectate. Sent through
-- Session.report (OP.ANALYTICS); the server validates and dedupes. Nothing here affects the game.
-- Every STATE_EVERY_S (and right before leaving) a snapshot: what is happening to the player, where
-- they stand on land, and the frame rate. The server keeps the latest and logs it when the match ends
-- with the player quitting or leaving (why do players close the game ~2 minutes in? 2026-09-28).
--
-- Once a match, the first SLOW_WINDOW_S in a row under SLOW_FPS is reported with what the frame was
-- made of ("slow": Telemetry.slow_cause). A player's report, 2026-10-09: down to about 3 fps
-- near the end of a match, on a desktop, and nothing here could say on what: a MIRV's
-- warheads did that (Map/TrailBudget) and the player had seen none.
--
-- UIRoot drives it: bind(state) on every state change, tick() once a second, title_shown(),
-- help(where), spectate(); UICtx.send passes every intent to on_intent(intent).

local UITheme = require("./UITheme")

local Telemetry = {}
Telemetry.__index = Telemetry

local MODE_SOLO, MODE_MULTI = 1, 2

Telemetry.STATE_EVERY_S = 10
--- Land changes over this window decide "Losing land" / "Growing" (by more than LAND_CHANGE of it).
Telemetry.LAND_WINDOW_S = 30
Telemetry.LAND_CHANGE = 0.03
--- No intent sent for this long: "Idle".
Telemetry.IDLE_S = 60
--- "slow": a window of SLOW_WINDOW_S under SLOW_FPS, the window in front the whole time, no sooner
--- than SLOW_AFTER_S into the match (its first seconds build the map). A frame longer than
--- SLOW_STALL_S is the game set aside, not a slow frame: its window does not count.
Telemetry.SLOW_FPS = 12
Telemetry.SLOW_WINDOW_S = 10
Telemetry.SLOW_AFTER_S = 30
Telemetry.SLOW_STALL_S = 2.0
--- slow_cause: this many munitions in flight are the cause whatever else is going on; our own script
--- is, when it is SLOW_SCRIPT_SHARE of the frame or more; else the engine: its GPU time or its
--- render CPU time (Stats.RenderGPUFrameTime / RenderCPUFrameTime, averaged over the window), the
--- bigger one when it is SLOW_ENGINE_SHARE of the frame or more, or neither.
Telemetry.SLOW_NUKES = 40
--- The map's parts besides units, labels and territory (MapView.perf_stats keys), each its own cause
--- "map_<part>"; "map" is what none of them holds.
Telemetry.MAP_PARTS = { "camera", "glow", "roads", "ranges", "structures", "fx", "fronts", "markers", "input" }
Telemetry.SLOW_SCRIPT_SHARE = 0.5
Telemetry.SLOW_ENGINE_SHARE = 1 / 3

function Telemetry.new(ctx: any)
	local self = setmetatable({}, Telemetry)
	self.ctx = ctx
	self._conns = {}
	--- the match being reported: { state, me, mode, map, minutes, sent_min, spawned, attacked, ended }
	self._match = nil
	self._title_sent = false
	self._title_wanted = false
	--- matches reported started this session, and the matches counted before it (nil: the saved
	--- [stats] section's); matches_before() is what the server counts
	self.matches_started = 0
	self.matches_base = nil :: number?
	--- frame rate over the current state window
	self._frames = 0
	self._frame_time = 0.0
	--- the "slow" window: frames, their time, whether it counts, and the local Sim's work at its start
	self._slow_frames = 0
	self._slow_time = 0.0
	self._slow_at = os.clock()
	self._slow_void = false
	self._slow_step_s = 0.0
	--- the other script clocks at the window's start: Session.process, the network handler, the
	--- HUD's own step and the UI kit's (cumulative seconds, see _script_clocks)
	self._slow_clocks = { process = 0.0, net = 0.0, ui = 0.0, kit = 0.0 }
	--- UIRoot's { process, kit } (cumulative seconds), set by UIRoot
	self.ui_perf = nil
	--- the engine's own render times summed over the window (s), and where they are read (nil: nowhere)
	self._slow_render_s = 0.0
	self._slow_gpu_s = 0.0
	self._stats = nil
	--- the game's window is in front (a window behind others is drawn slowly on purpose)
	self._focused = true
	if typeof ~= nil and typeof(game) == "Instance" then
		pcall(function()
			local stats = game:GetService("Stats")
			local _ = stats.RenderCPUFrameTime + stats.RenderGPUFrameTime
			self._stats = stats
		end)
		pcall(function()
			local UIS = game:GetService("UserInputService")
			UIS.WindowFocusReleased:Connect(function()
				self._focused = false
				self._slow_void = true
			end)
			UIS.WindowFocused:Connect(function()
				self._focused = true
				self._slow_void = true
			end)
		end)
	end
	return self
end

--- Every frame (UIRoot._process): counts frames for the snapshot's frame rate.
function Telemetry.frame(self, dt: number)
	self._frames += 1
	self._frame_time += dt
	self._slow_frames += 1
	self._slow_time += dt
	if dt > Telemetry.SLOW_STALL_S then
		self._slow_void = true
	end
	local stats = self._stats
	if stats ~= nil then
		self._slow_render_s += stats.RenderCPUFrameTime
		self._slow_gpu_s += stats.RenderGPUFrameTime
	end
end

--- What a slow frame was made of, as a key of server/Analytics.SLOW_CAUSES. `s`, all per frame:
--- frame_ms (the frame's length), nukes (munitions in flight), map (MapView.perf_stats: ms by layer,
--- and `total`), sim_ms (the local Sim's steps), net_ms (the network handler: a public match's
--- updates decoded and applied), session_ms (the rest of Session.process), ui_ms (the HUD's own
--- step), hud_ms (the UI kit's), render_ms and gpu_ms (the engine's render CPU and GPU time).
---   * v71 and v72 counted the map, the kit and the Sim only. A public match's biggest script is the
---     network handler (7 ms a tick on a Mac in a match's first minute), so those versions named the
---     engine for frames that were ours.
function Telemetry.slow_cause(s: any): string
	if (tonumber(s.nukes) or 0) >= Telemetry.SLOW_NUKES then
		return "nukes"
	end
	local map = if type(s.map) == "table" then s.map else {}
	local function ms(v: any): number
		local n = tonumber(v) or 0
		return if n == n and n > 0 then n else 0
	end
	local units, labels, territory = ms(map.units), ms(map.labels), ms(map.territory)
	local parts = {
		{ "units", units },
		{ "labels", labels },
		{ "territory", territory },
	}
	-- the rest of the map by its own parts (2026-10-27: the rest as one was half of all slow frames,
	-- 70% of them on phones), and what none of them holds
	local rest = ms(map.total) - units - labels - territory
	for _, k in Telemetry.MAP_PARTS do
		local v = ms(map[k])
		table.insert(parts, { "map_" .. k, v })
		rest -= v
	end
	for _, part in {
		{ "map", math.max(rest, 0) },
		{ "hud", ms(s.hud_ms) },
		{ "sim", ms(s.sim_ms) },
		{ "net", ms(s.net_ms) },
		{ "session", ms(s.session_ms) },
		{ "ui", ms(s.ui_ms) },
	} do
		table.insert(parts, part)
	end
	local total, top = 0.0, parts[1]
	for _, part in parts do
		total += part[2]
		if part[2] > top[2] then
			top = part
		end
	end
	if total >= Telemetry.SLOW_SCRIPT_SHARE * math.max(ms(s.frame_ms), 1e-3) then
		return top[1]
	end
	local frame = math.max(ms(s.frame_ms), 1e-3)
	local gpu, render = ms(s.gpu_ms), ms(s.render_ms)
	if math.max(gpu, render) >= Telemetry.SLOW_ENGINE_SHARE * frame then
		return if gpu >= render then "gpu" else "render"
	end
	return "engine"
end

--- The script clocks outside the map and the Sim, cumulative seconds: Session.process, the network
--- handler, the HUD's step and the UI kit's.
function Telemetry._script_clocks(self): { [string]: number }
	local session = self.ctx.session
	local perf = if session ~= nil then session.perf else nil
	local net = if session ~= nil and type(session.env) == "table" then session.env.net else nil
	local ui = self.ui_perf
	return {
		process = if type(perf) == "table" then tonumber(perf.process_s) or 0.0 else 0.0,
		net = if type(net) == "table" then tonumber(net.busy_s) or 0.0 else 0.0,
		ui = if type(ui) == "table" then tonumber(ui.process) or 0.0 else 0.0,
		kit = if type(ui) == "table" then tonumber(ui.kit) or 0.0 else 0.0,
	}
end

--- Once a second (tick): closes a "slow" window when it is SLOW_WINDOW_S old, and reports the match's
--- first one that was slow. `m`: the match's record (it may have ended: a spectator's frames count).
function Telemetry._slow_check(self, m: any)
	local now = os.clock()
	if now - self._slow_at < Telemetry.SLOW_WINDOW_S then
		return
	end
	local frames, time, void = self._slow_frames, self._slow_time, self._slow_void or not self._focused
	local render_s, gpu_s = self._slow_render_s, self._slow_gpu_s
	self._slow_render_s, self._slow_gpu_s = 0.0, 0.0
	local ctx = self.ctx
	local perf = if ctx.session ~= nil then ctx.session.perf else nil
	local step_s = if type(perf) == "table" then tonumber(perf.step_s) or 0.0 else 0.0
	local sim_s = math.max(step_s - self._slow_step_s, 0.0)
	local clocks, was = self:_script_clocks(), self._slow_clocks
	self._slow_clocks = clocks
	self._slow_frames, self._slow_time, self._slow_at, self._slow_void = 0, 0.0, now, false
	self._slow_step_s = step_s
	local st = m.state
	if m.slow_sent or void or frames < 2 or time <= 0 or st == nil then
		return
	end
	local fps = frames / time
	if fps >= Telemetry.SLOW_FPS or Telemetry.minutes(st) * 60 < Telemetry.SLOW_AFTER_S then
		return
	end
	local nukes = 0
	for _ in st.nukes or {} do
		nukes += 1
	end
	local map = nil
	local world = ctx.world
	if type(world) == "table" and type(world.perf_stats) == "function" then
		local ok, stats = pcall(world.perf_stats, world)
		map = if ok then stats else nil
	end
	local mem_mb = 0.0
	pcall(function()
		mem_mb = game:GetService("Stats"):GetTotalMemoryUsageMb()
	end)
	local function per_frame(k: string): number
		return math.max(clocks[k] - (was[k] or 0.0), 0.0) * 1000 / frames
	end
	local cause = Telemetry.slow_cause({
		frame_ms = 1000 / fps,
		nukes = nukes,
		map = map,
		hud_ms = per_frame("kit"),
		sim_ms = sim_s * 1000 / frames,
		net_ms = per_frame("net"),
		session_ms = math.max(per_frame("process") - sim_s * 1000 / frames, 0.0),
		ui_ms = per_frame("ui"),
		render_ms = render_s * 1000 / frames,
		gpu_ms = gpu_s * 1000 / frames,
	})
	m.slow_sent = self:_send("slow", cause, Telemetry.minutes(st), math.floor(fps + 0.5))
	if m.slow_sent and mem_mb > 0 then
		self:_send("slow_mem", cause, math.floor(mem_mb + 0.5))
	end
end

--- What is happening to `me` now (the snapshot's first field). `land` holds {clock, tiles} samples.
function Telemetry.situation(st: any, me: number, land: { { number } }, idle_s: number): string
	local o = st.owners[me]
	if (tonumber(st.playing_since) or -1) < 0 then
		return "Choosing spawn"
	end
	if o == nil or o.tiles <= 0 then
		return "Not spawned"
	end
	for _, a in st.attacks or {} do
		if a.target == me and a.attacker ~= me and not a.retreating then
			return "Under attack"
		end
	end
	local was = if #land > 0 then land[1][2] else o.tiles
	if was > 0 and o.tiles < was * (1 - Telemetry.LAND_CHANGE) then
		return "Losing land"
	end
	if idle_s >= Telemetry.IDLE_S then
		return "Idle"
	end
	if o.tiles > was * (1 + Telemetry.LAND_CHANGE) then
		return "Growing"
	end
	return "Holding"
end

--- Where `me` stands on land among the living.
function Telemetry.standing(st: any, me: number): string
	for i, o in st:ranking() do
		if o.id == me then
			return if i <= 3 then "Top 3" elseif i <= 10 then "Top 10" else "Lower"
		end
	end
	return "No land"
end

--- The snapshot for the open match (sent now; frame counters restart).
function Telemetry._send_state(self, m: any)
	local st = m.state
	local now = os.clock()
	local o = st.owners[m.me]
	-- land samples at most LAND_WINDOW_S old (the oldest is what "was")
	table.insert(m.land, { now, if o then o.tiles else 0 })
	while #m.land > 1 and now - m.land[1][1] > Telemetry.LAND_WINDOW_S do
		table.remove(m.land, 1)
	end
	local fps = if self._frame_time > 0.25 then self._frames / self._frame_time else 0
	self._frames = 0
	self._frame_time = 0.0
	m.state_at = now
	self:_send(
		"state",
		Telemetry.situation(st, m.me, m.land, now - m.last_intent),
		Telemetry.standing(st, m.me),
		math.floor(fps + 0.5)
	)
end

function Telemetry._send(self, kind: string, a: any?, b: any?, c: any?): boolean
	local s = self.ctx.session
	if s ~= nil and type(s.report) == "function" then
		return s:report(kind, a, b, c) == true
	end
	return false
end

--- Minutes since play began in `st` (0 before).
function Telemetry.minutes(st: any): number
	local since = tonumber(st and st.playing_since) or -1
	if since < 0 then
		return 0.0
	end
	local Defs = UITheme.core("Defs")
	return math.max(0.0, (st.tick - since) / Defs.TICK_RATE / 60.0)
end

function Telemetry._open(self): any
	local m = self._match
	if m ~= nil and not m.ended then
		return m
	end
	return nil
end

--- The player's matches before the one being played (before the next one, between matches): the
--- server's count when this session began (the saved [stats] section) and the matches started since.
function Telemetry.matches_before(self): number
	local base = self.matches_base
	if base == nil then
		local s = self.ctx.session
		local stats = if s ~= nil and type(s.load_settings) == "function" then s:load_settings("stats") else nil
		base = if type(stats) == "table" then tonumber(stats.matches) or 0 else 0
	end
	local n = self.matches_started
	if self:_open() ~= nil and n > 0 then
		n -= 1
	end
	return (base :: number) + n
end

--- "Replay as new player": no match counted again.
function Telemetry.new_player(self)
	self.matches_base = 0
	self.matches_started = 0
end

function Telemetry.title_shown(self)
	self._title_wanted = true
	if not self._title_sent then
		-- (retried by tick() when the connection wasn't up yet)
		self._title_sent = self:_send("title")
	end
end

function Telemetry.help(self, where: string)
	self:_send("help", where)
end

function Telemetry.spectate(self)
	self:_send("spectate")
end

--- A new state (match, title backdrop, or a multiplayer resync). Leaving a match before its end
--- reports "left" — except for a multiplayer state, which tick() matches up with the open match.
function Telemetry.bind(self, st: any)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	local m = self:_open()
	if m ~= nil and m.state ~= st and not (m.multi and self.ctx.state_mode == MODE_MULTI) then
		m.ended = true
		pcall(self._send_state, self, m)
		self:_send("left", m.minutes)
	end
	if st == nil then
		return
	end
	local function c(name: string, cb: (...any) -> ())
		local sig = st[name]
		if type(sig) == "table" and sig.Connect then
			table.insert(self._conns, sig:Connect(cb))
		end
	end
	c("owner_eliminated", function(id: number, killer: number)
		local mm = self:_open()
		if mm == nil or mm.state ~= st or id ~= mm.me then
			return
		end
		mm.ended = true
		local Defs = UITheme.core("Defs")
		local k = st.owners[killer]
		local kind = "unknown"
		if k ~= nil then
			kind = if k.kind == Defs.KIND_NATION then "nation" elseif k.kind == Defs.KIND_TRIBE then "tribe" else "player"
		end
		self:_send("eliminated", Telemetry.minutes(st), kind, killer)
	end)
	c("game_over", function(winner: number, _reason: number)
		local mm = self:_open()
		if mm == nil or mm.state ~= st then
			return
		end
		mm.ended = true
		local rank = 0
		for i, o in st:ranking() do
			if o.id == mm.me then
				rank = i
				break
			end
		end
		self:_send("over", winner ~= 0 and winner == mm.me, Telemetry.minutes(st), rank)
	end)
end

--- Once a second: start the match once this client controls a nation in it, then spawned, whole
--- minutes alive.
function Telemetry.tick(self)
	local ctx = self.ctx
	if self._title_wanted and not self._title_sent then
		self:title_shown()
	end
	local st = ctx.state
	local sm = ctx.state_mode
	if st == nil or (sm ~= MODE_SOLO and sm ~= MODE_MULTI) then
		return
	end
	local me = st.local_owner or 0
	if me == 0 then
		return
	end
	local m = self._match
	if m == nil or m.state ~= st then
		if m ~= nil and not m.ended and m.multi then
			if sm == MODE_MULTI and m.me == me and m.map == st.map_id then
				m.state = st -- the same match after a resync
			else
				m.ended = true
				pcall(self._send_state, self, m)
				self:_send("left", m.minutes)
				m = nil
			end
		else
			m = nil
		end
		if m == nil then
			local mode = "public"
			if sm == MODE_SOLO then
				local d = math.clamp(tonumber(ctx.session and ctx.session.difficulty) or 1, 0, 2)
				mode = "solo" .. tostring(math.floor(d))
			end
			m = {
				state = st,
				me = me,
				multi = sm == MODE_MULTI,
				map = st.map_id,
				minutes = 0.0,
				sent_min = 0,
				spawned = false,
				attacked = false,
				ended = false,
				land = {},
				last_intent = os.clock(),
				state_at = -math.huge,
			}
			self._match = m
			self.matches_started += 1
			self:_send("match_start", mode, tostring(st.map_id or ""))
		end
	end
	self:_slow_check(m)
	if m.ended then
		return
	end
	if os.clock() - m.state_at >= Telemetry.STATE_EVERY_S then
		self:_send_state(m)
	end
	local o = st.owners[me]
	if not m.spawned and o ~= nil and o.tiles > 0 then
		m.spawned = true
		self:_send("spawned")
	end
	if o ~= nil and o.alive then
		m.minutes = Telemetry.minutes(st)
		local whole = math.floor(m.minutes)
		if whole > m.sent_min then
			m.sent_min = whole
			self:_send("alive", m.minutes)
		end
	end
end

--- Every intent the player sends (UICtx.send): the first attack or boat of the match; any intent
--- means the player is not idle.
function Telemetry.on_intent(self, intent: any)
	local m = self:_open()
	if m == nil or type(intent) ~= "table" then
		return
	end
	m.last_intent = os.clock()
	if m.attacked then
		return
	end
	if intent.type == "attack" or intent.type == "boat" then
		m.attacked = true
		self:_send("attack")
	end
end

return Telemetry
