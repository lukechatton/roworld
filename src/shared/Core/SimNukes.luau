--!native
-- Port of scripts/core/sim_nukes.gd (SimNukes, mixin of the flattened Sim class).
-- Atom bombs, hydrogen bombs and MIRVs: silo launch, SAM interception, blasts and fallout.
--
-- Event conventions (see DESIGN.md §4): a NUKE event announces every missile (MIRV warheads
-- included). BOOM with radius > 0 is a detonation; radius 0 means the missile was shot down
-- mid-air at that tile; radius -1 means a MIRV bus split into warheads at that tile. SAM_LAUNCH
-- announces a SAM firing at a bomb / warhead (it hits at intercept_tick).
--
-- Nukes fly an arc (Rules.nuke_arc: a Bezier bowed toward the top of the map, constant speed
-- along it), the same curve the renderer draws; the flight time is its length over the nuke's speed.
--
-- Luau notes: `traj` is a 1-based array; trajectory indices (`k`, `sam_k`, `plan_k`) keep the
-- GDScript 0-based meaning (ticks since launch), so traj[k + 1] is the tile at tick k.

local Defs = require("./Defs")
local Coop = require("../Net/Coop")
local Ev = require("./Ev")
local Rules = require("./Rules")
local SimState = require("./SimState")

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readi32 = buffer.readi32

local a_an = SimState.a_an
local cap_first = SimState.cap_first

local S_SAM = Defs.S_SAM
local S_SILO = Defs.S_SILO
local U_TRANSPORT = Defs.U_TRANSPORT
local N_ATOM = Defs.N_ATOM
local N_HYDROGEN = Defs.N_HYDROGEN
local N_MIRV = Defs.N_MIRV
local N_WARHEAD = Defs.N_WARHEAD
local N_SCATTER = Defs.N_SCATTER
local N_SHELL = Defs.N_SHELL
local F_FALLOUT = Defs.F_FALLOUT

local SimNukes = {}

local function nuke_title(kind: number): string
	return Defs.NUKE_TITLES[kind]
end

export type Nuke = {
	uid: number,
	kind: number,
	owner: number,
	from_tile: number,
	to_tile: number,
	launch_tick: number,
	flight: number,
	--- Rules.nuke_arc: its flight path (the arc the renderer draws; traj samples it)
	arc: any,
	target_owner: number,
	dead: boolean,
	traj: { number },
	cands: { number },
	cand_tick: number,
	plan_fire: { [number]: number },
	plan_k: { [number]: number },
	sam_sid: number,
	sam_fire_tick: number,
	sam_hit_tick: number,
	sam_k: number,
}

local Nuke = {}
SimNukes.Nuke = Nuke

function Nuke.new(): Nuke
	return {
		uid = 0,
		kind = 0,
		owner = 0,
		from_tile = 0,
		to_tile = 0,
		launch_tick = 0,
		flight = 1,
		arc = nil,
		target_owner = 0,
		dead = false,
		-- Ground tile under the missile at each tick of its flight (traj[k + 1] = tick k since
		-- launch), computed when a SAM might reach it.
		traj = {},
		-- SAM interception planning: candidate SAM sids, refreshed every 30
		-- ticks, and per SAM the planned fire tick (-1 unreachable) and trajectory index of the
		-- intercept.
		cands = {},
		cand_tick = -100000,
		plan_fire = {},
		plan_k = {},
		-- Set once a SAM missile is on its way.
		sam_sid = 0,
		sam_fire_tick = 0,
		sam_hit_tick = 0,
		sam_k = 0,
	}
end

-- Ground tile under a missile flying from tile a to tile b (straight ground track on the flat map)
-- at fraction w of its flight, on a grid `W` tiles wide.

function SimNukes.install(C)
	function C:_init_nukes()
		self.nukes = {} :: { Nuke }
		self.nukes_launched = 0
		-- MIRVs launched this match (each one raises the next MIRV's price by Rules.MIRV_COST_STEP).
		self.mirvs_launched = 0
	end

	-- =========================================================================================
	-- Launch
	-- =========================================================================================

	-- Nuke intent. Returns true when a missile left a silo.
	function C:launch_nuke(id: number, kind_name: string, t: number): boolean
		local kind = Defs.nuke_kind_from_name(kind_name)
		if kind < 0 or kind == N_WARHEAD or kind == N_SHELL or t < 0 or t >= self.N then
			return false
		end
		-- the Arsenal's munitions need their unlock (SimArsenal)
		if not self:has_unlock(id, Defs.NUKE_UNLOCK[kind] or 0) then
			self:msg(id, Defs.MSG_INFO, string.format("Unlock the %s in the Arsenal first", nuke_title(kind)))
			return false
		end
		-- a strike (air strike, slug) leaves its own structure, takes no land and costs nothing
		local strike = Rules.NUKE_FLAT[kind] == true
		local tg = readi32(self.owner, t * 4)
		if tg == id then
			self:msg(
				id,
				Defs.MSG_INFO,
				if strike then "You can't strike your own land" else "You can't nuke your own land"
			)
			return false
		end
		if tg ~= 0 and self:allied(id, tg) then
			self:msg(
				id,
				Defs.MSG_INFO,
				if self:same_team(id, tg)
					then (if strike then "You can't strike a teammate" else "You can't nuke a teammate")
					else (if strike then "You can't strike an ally" else "You can't nuke an ally")
			)
			return false
		end
		-- Team games: no atom or hydrogen bomb with a teammate's
		-- structure inside its outer radius
		if self.team_mode and (kind == N_ATOM or kind == N_HYDROGEN) then
			local _, outer = self.R.nuke_radii(kind)
			local r = math.ceil(outer)
			local o2 = outer * outer
			for _, s in self:structs_in_box(t, r, r) do
				if s.owner ~= id and self:same_team(id, s.owner) and self.range_d2(t, s.tile) <= o2 then
					self:msg(id, Defs.MSG_INFO, "A teammate's building is too close")
					return false
				end
			end
		end
		local cost = Rules.nuke_cost(kind_name, self.mirvs_launched)
		if self.o_gold[id] < cost then
			self:msg(id, Defs.MSG_INFO, string.format("Not enough gold for %s", a_an(nuke_title(kind))))
			return false
		end
		-- Launch site: the nearest (manhattan) finished silo with a loaded missile. (A strike: the
		-- nearest loaded airfield within its reach, or railgun.)
		local geo_manhattan = self.geo_manhattan
		local launcher = Rules.NUKE_LAUNCHER[kind]
		local reload = Rules.RELOAD_TICKS[launcher]
		local reach = self.R.launch_range(kind)
		local reach2 = reach * reach
		local range_d2 = self.range_d2
		local silo = nil
		local bd = 0.0
		local out_of_reach = false
		for _, s in self:structs_of(id, launcher) do
			if not s.active or self:ready_missiles(s, reload) <= 0 then
				continue
			end
			if reach > 0 and range_d2(s.tile, t) > reach2 then
				out_of_reach = true
				continue
			end
			local d = geo_manhattan(s.tile, t)
			if silo == nil or d < bd then
				bd = d
				silo = s
			end
		end
		if silo == nil then
			local what = string.lower(Defs.STRUCT_TITLES[launcher])
			self:msg(
				id,
				Defs.MSG_INFO,
				if out_of_reach
					then string.format("That is out of your %s's reach", what)
					else string.format("No %s is ready", what)
			)
			return false
		end
		local tick = self.tick
		self.o_gold[id] -= cost
		table.insert(silo.shots, self:shot_stamp(silo))
		self:ev({ Ev.STRUCT_SHOTS, silo.sid, table.clone(silo.shots) })
		local arc = self.R.munition_arc(self.W, self.H, silo.tile, t, kind)
		local n = self:_spawn_nuke(kind, id, silo.tile, t, self.R.nuke_arc_ticks(arc, kind), arc)
		n.target_owner = tg
		if strike then
			self:msg(id, Defs.MSG_INFO, string.format("%s on its way to %s", nuke_title(kind), self:name_of(tg)))
			return true
		end
		self.nukes_launched += 1
		if kind == N_MIRV then
			self.mirvs_launched += 1
		elseif kind == N_SCATTER then
			self:_scatter_warheads(id, silo.tile, t, n.flight)
		end
		local o_name = self.o_name
		if tg ~= 0 then
			self:add_grudge(tg, id, Rules.NUKE_GRUDGE_TICKS)
			self.o_attacked_tick[tg] = tick
			self:msg(tg, Defs.MSG_ALERT, string.format("%s launched %s at you!", o_name[id], a_an(nuke_title(kind))))
		end
		self:msg(id, Defs.MSG_INFO, string.format("%s launched at %s", nuke_title(kind), self:name_of(tg)))
		if kind ~= N_ATOM then
			for _, h in self.humans do
				if h ~= tg and h ~= id then
					self:msg(
						h,
						Defs.MSG_ALERT,
						string.format("%s launched %s at %s", o_name[id], a_an(nuke_title(kind)), self:name_of(tg))
					)
				end
			end
		end
		if kind ~= N_MIRV then
			self:_break_nuked_alliances(id, t, kind)
		end
		self:_on_nuke_launched(id, tg, kind)
		return true
	end

	-- Alliance breaking: allies with at least nukeAllianceBreakThreshold weighted
	-- full-size tiles (inner radius 1, outer ring 0.5) inside the blast lose their alliance with the
	-- launcher.
	function C:_break_nuked_alliances(id: number, t: number, kind: number)
		if self.o_ally_count[id] <= 0 then
			return
		end
		local range_d2 = self.range_d2
		local inner, outer = self.R.nuke_radii(kind)
		local weight = {}
		local order = {}
		local inner2 = inner * inner
		local owner = self.owner
		for _, c in self:disk_tiles(t, outer, true) do
			local o = readi32(owner, c * 4)
			if o <= 0 or o == id or not self:has_alliance(id, o) then
				continue
			end
			local w = weight[o]
			if w == nil then
				w = 0.0
				table.insert(order, o)
			end
			weight[o] = w + (if range_d2(t, c) <= inner2 then 1.0 else 0.5)
		end
		for _, o in order do
			if weight[o] * self.R.K_AREA >= Rules.NUKE_ALLIANCE_BREAK_FULL then
				self:end_alliance(id, o, id)
			end
		end
	end

	-- Hook for the AI.
	function C:_on_nuke_launched(_id: number, _tg: number, _kind: number) end

	function C:_spawn_nuke(kind: number, id: number, from_tile: number, to_tile: number, flight: number, arc: any?): Nuke
		local tick = self.tick
		local n = Nuke.new()
		n.uid = self.next_uid
		self.next_uid += 1
		n.kind = kind
		n.owner = id
		n.from_tile = from_tile
		n.to_tile = to_tile
		n.launch_tick = tick
		n.flight = math.max(flight, 1)
		n.arc = arc or self.R.munition_arc(self.W, self.H, from_tile, to_tile, kind)
		n.target_owner = readi32(self.owner, to_tile * 4)
		table.insert(self.nukes, n)
		self:ev({ Ev.NUKE, n.uid, kind, id, from_tile, to_tile, tick, n.flight })
		return n
	end

	-- =========================================================================================
	-- Flight, interception, detonation
	-- =========================================================================================

	function C:nukes_tick()
		self:_sam_tick()
		local list = self.nukes
		local count = #list
		local tick = self.tick
		for i = 1, count do
			local n = list[i]
			if n.dead then
				continue
			end
			if n.sam_sid ~= 0 and tick >= n.sam_hit_tick and self:_sam_intercept(n) then
				continue
			end
			if tick >= n.launch_tick + n.flight then
				n.dead = true
				if n.kind == N_MIRV then
					self:_split_mirv(n)
				elseif Rules.NUKE_FLAT[n.kind] then
					self:_strike(n) -- (a shell, an air strike, a slug: SimArsenal)
				else
					self:_detonate(n)
				end
				Coop.check() -- (a local match's step is spread over frames: Session._local_process)
			end
		end
		local w = 0
		local m = #list
		for i = 1, m do
			local n2 = list[i]
			if not n2.dead then
				w += 1
				list[w] = n2
			end
		end
		for i = m, w + 1, -1 do
			list[i] = nil
		end
	end

	-- SAM targeting: every non-friendly finished SAM plans, for each
	-- bomb or warhead it could reach, the latest tick to fire so its missile (12 full-size tiles per
	-- tick) meets the missile at the first trajectory tile that is inside the SAM's range and
	-- targetable (within 150 full-size tiles of the target or launch point); it fires on that tick if a
	-- missile is loaded (hydrogen bombs first, then targets nearest the SAM, then the most
	-- urgent). Always a hit.
	function C:_sam_tick()
		local list = self.nukes
		if #list == 0 then
			return
		end
		local tick = self.tick
		local structs = self.structs
		local geo_manhattan = self.geo_manhattan
		local K_LIN = self.R.K_LIN
		local sams = nil
		local fires = {}
		for _, n in list do
			if n.dead or n.sam_sid ~= 0 or Rules.NUKE_INTERCEPT_P[n.kind] <= 0 then
				continue
			end
			if tick >= n.cand_tick then
				if sams == nil then
					sams = {}
					for _, st in self.struct_list do
						if not st.dead and st.kind == S_SAM and st.active then
							table.insert(sams, st)
						end
					end
				end
				self:_sam_candidates(n, sams)
			end
			if #n.cands == 0 then
				continue
			end
			for _, sid in n.cands do
				local s = structs[sid]
				if s == nil or s.dead or not s.active or s.owner == n.owner or self:allied(s.owner, n.owner) then
					continue
				end
				local plan = n.plan_fire[sid]
				if plan == nil then
					plan = -3
				end
				if plan == -3 or (plan >= 0 and plan < tick) then
					self:_sam_plan(n, s)
					plan = n.plan_fire[sid]
				end
				if plan >= 0 and plan <= tick + 1 then
					local score = (if n.kind == N_HYDROGEN then 70001 else 0)
						+ math.max(0, 200000 - Defs.trunc(geo_manhattan(s.tile, n.to_tile) * K_LIN) * 1000)
						+ math.max(0, 10000 - (n.launch_tick + n.flight - tick) * 100)
					table.insert(fires, { score, n, s })
				end
			end
		end
		if #fires == 0 then
			return
		end
		-- Godot's sort_custom (unstable): equal scores end up in the Godot version's order.
		Defs.godot_sort(fires, function(a, b)
			return a[1] > b[1]
		end)
		for _, f in fires do
			local n2: Nuke = f[2]
			local s2 = f[3]
			if n2.sam_sid ~= 0 or self:ready_missiles(s2, Rules.SAM_COOLDOWN_TICKS) <= 0 then
				continue
			end
			table.insert(s2.shots, tick)
			self:ev({ Ev.STRUCT_SHOTS, s2.sid, table.clone(s2.shots) })
			local k = n2.plan_k[s2.sid]
			local t = n2.traj[k + 1]
			n2.sam_sid = s2.sid
			n2.sam_k = k
			n2.sam_fire_tick = tick
			n2.sam_hit_tick = tick + self:_sam_ticks_to(s2.tile, t)
			self:ev({ Ev.SAM_LAUNCH, s2.sid, n2.uid, tick, n2.sam_hit_tick, true })
		end
	end

	-- SAMs that might reach `n`: within max SAM range + the targetable zone of its target or
	-- launch.
	function C:_sam_candidates(n: Nuke, sams)
		n.cand_tick = self.tick + 30
		table.clear(n.plan_fire)
		table.clear(n.plan_k)
		local cands = {}
		n.cands = cands
		local range_d2 = self.range_d2
		local K_LIN = self.R.K_LIN
		local reach = Rules.SAM_MAX_RANGE_FULL / K_LIN + Rules.NUKE_TARGETABLE_FULL / K_LIN
		local r2 = reach * reach
		for _, s in sams do
			if s.owner == n.owner then
				continue
			end
			if range_d2(s.tile, n.to_tile) <= r2 or range_d2(s.tile, n.from_tile) <= r2 then
				table.insert(cands, s.sid)
			end
		end
		if #cands > 0 and #n.traj == 0 then
			-- the tile under the nuke on each tick of its flight, along its arc (Rules.nuke_arc: the
			-- curve the renderer draws)
			local W, H = self.W, self.H
			local R = self.R
			local arc = n.arc or R.munition_arc(W, H, n.from_tile, n.to_tile, n.kind)
			n.arc = arc
			local flight = n.flight
			local traj = table.create(flight + 1)
			for k = 0, flight do
				local x, y = R.nuke_arc_at(arc, k / flight)
				traj[k + 1] = math.clamp(math.floor(y), 0, H - 1) * W + math.clamp(math.floor(x), 0, W - 1)
			end
			n.traj = traj
		end
	end

	-- Ticks a SAM missile needs from `from` to `to` (manhattan full-size tiles / 12, rounded up).
	function C:_sam_ticks_to(from: number, to: number): number
		return math.ceil(self.geo_manhattan(from, to) * self.R.K_LIN / Rules.SAM_MISSILE_SPEED_FULL)
	end

	-- Interception tile: the first future trajectory tile in range and targetable that the
	-- SAM's missile can reach in time (or the tile before detonation when the target is in range).
	function C:_sam_plan(n: Nuke, s)
		local tick = self.tick
		local traj = n.traj
		local sid = s.sid
		local cur = tick - n.launch_tick
		local last = n.flight
		local R = self.R
		local range_d2 = self.range_d2
		local zone = Rules.NUKE_TARGETABLE_FULL / R.K_LIN
		local z2 = zone * zone
		local rmax = Rules.SAM_MAX_RANGE_FULL / R.K_LIN
		local rmax2 = rmax * rmax
		local inc = 0
		local lastd = -1.0
		for k = math.max(cur, 0), last - 1 do
			local t = traj[k + 1]
			local d = range_d2(s.tile, t)
			inc = if lastd >= 0.0 and d > lastd then inc + 1 else 0
			lastd = d
			local nt = k - cur
			local rr = R.sam_range_at(s.level, tick + nt - s.up_tick)
			if d <= rr * rr and (range_d2(n.to_tile, t) < z2 or range_d2(n.from_tile, t) < z2) then
				local st = self:_sam_ticks_to(s.tile, t)
				if nt >= st then
					n.plan_fire[sid] = tick + nt - st
					n.plan_k[sid] = k
					return
				end
			end
			if inc > 3 and d > rmax2 then
				break
			end
		end
		local kf = last - 1
		if kf >= cur then
			local rf = R.sam_range_at(s.level, tick + (last - cur) - s.up_tick)
			if range_d2(s.tile, n.to_tile) <= rf * rf then
				local st2 = self:_sam_ticks_to(s.tile, traj[kf + 1])
				if kf - cur >= st2 then
					n.plan_fire[sid] = tick + kf - cur - st2
					n.plan_k[sid] = kf
					return
				end
			end
		end
		n.plan_fire[sid] = -1
	end

	-- A SAM missile arriving: the bomb / warhead is destroyed (BOOM radius 0 at the ground
	-- tile under the intercept point) unless the SAM was lost meanwhile (then the target is free
	-- again).
	function C:_sam_intercept(n: Nuke): boolean
		local s = self.structs[n.sam_sid]
		if s == nil or s.dead or s.owner == n.owner then
			n.sam_sid = 0
			n.cand_tick = self.tick
			return false
		end
		n.dead = true
		self:ev({ Ev.BOOM, n.uid, n.kind, n.traj[n.sam_k + 1], 0, n.owner })
		if n.kind ~= N_WARHEAD then
			self:msg(
				s.owner,
				Defs.MSG_GOOD,
				string.format("Your SAM shot down %s from %s", a_an(nuke_title(n.kind)), self.o_name[n.owner])
			)
			self:msg(
				n.owner,
				Defs.MSG_BAD,
				string.format("Your %s was intercepted by %s", nuke_title(n.kind), self.o_name[s.owner])
			)
		end
		return true
	end

	-- Snapshot rows of SAM missiles in flight: [sam_sid, nuke_uid, fire_tick, intercept_tick, true].
	function C:sam_rows(): { { any } }
		local out = {}
		for _, n in self.nukes do
			if not n.dead and n.sam_sid ~= 0 then
				table.insert(out, { n.sam_sid, n.uid, n.sam_fire_tick, n.sam_hit_tick, true })
			end
		end
		return out
	end

	-- Missiles a SAM or silo can fire now: `level` minus those still reloading (each launch or
	-- upgrade reloads for `cooldown` ticks — a queue of missile timers).
	function C:ready_missiles(s, cooldown: number): number
		local shots = s.shots
		local n = #shots
		local tick = self.tick
		local k = 0
		while k < n and shots[k + 1] + cooldown <= tick do
			k += 1
		end
		if k > 0 then
			s.shots = table.move(shots, k + 1, n, 1, {})
		end
		return s.level - #s.shots
	end

	-- MIRV split: up to MIRV_WARHEADS warheads, aimed at the target's land within MIRV_SPREAD
	-- of the aim point and at least 55 full-size tiles (manhattan) apart, leave the bus when it arrives.
	function C:_split_mirv(n: Nuke)
		self:ev({ Ev.BOOM, n.uid, n.kind, n.to_tile, -1, n.owner })
		local tg = n.target_owner
		if tg > 0 and self:allied(n.owner, tg) then
			self:end_alliance(n.owner, tg, n.owner)
		end
		local R = self.R
		local W = self.W
		local range_d2 = self.range_d2
		local geo_manhattan = self.geo_manhattan
		local spread2 = R.MIRV_SPREAD * R.MIRV_SPREAD
		local gap = math.ceil(55.0 / R.K_LIN)
		local grid = {}
		local targets = { n.to_tile }
		SimNukes._mirv_mark(grid, W, n.to_tile, gap)
		local map = self.map
		local land_list = map.land_list
		local nlt = map.land_count
		local owner = self.owner
		local rng = self.rng
		local max_w = Rules.MIRV_WARHEADS
		for _ = 1, 8000 do
			if #targets >= max_w then
				break
			end
			local c = readi32(land_list, (rng:randi() % nlt) * 4)
			if readi32(owner, c * 4) ~= tg or tg == 0 or range_d2(n.to_tile, c) > spread2 then
				continue
			end
			if SimNukes._mirv_overlaps(grid, W, c, gap, geo_manhattan) then
				continue
			end
			table.insert(targets, c)
			SimNukes._mirv_mark(grid, W, c, gap)
		end
		for _, t in targets do
			local arc = R.nuke_arc(self.W, self.H, n.to_tile, t)
			local flight = R.nuke_arc_ticks(arc, N_WARHEAD) + rng:randi_range(0, 15)
			self:_spawn_nuke(N_WARHEAD, n.owner, n.to_tile, t, flight, arc).target_owner = tg
		end
	end

	-- Detonation: every tile of the inner radius and half of the outer ring (at
	-- random) is relinquished and left as fallout; each hit owner loses troops per full-size tile by
	-- nukeDeathFactor (its attacks and transports too), and every unit and structure inside the
	-- outer radius is destroyed.
	function C:_detonate(n: Nuke)
		local range_d2 = self.range_d2
		local inner, radius = self.R.nuke_radii(n.kind)
		local inner2 = inner * inner
		local to = n.to_tile
		local tiles = self:disk_tiles(to, radius, true)
		local lost = {}
		local before = {}
		local order = {}
		local owner = self.owner
		local flags = self.flags
		local d_flags = self.d_flags
		local o_tiles = self.o_tiles
		local rng = self.rng
		for _, t in tiles do
			if range_d2(to, t) > inner2 and rng:randi() % 2 == 0 then
				continue
			end
			local o = readi32(owner, t * 4)
			if o ~= 0 then
				if before[o] == nil then
					before[o] = o_tiles[o]
					lost[o] = 0
					table.insert(order, o)
				end
				lost[o] += 1
				self:set_owner(t, 0)
			end
			local f = readu8(flags, t)
			if bit32.band(f, F_FALLOUT) == 0 then
				f = bit32.bor(f, F_FALLOUT)
				writeu8(flags, t, f)
				table.insert(d_flags, t * 256 + f)
				self.fallout_count += 1
			end
		end
		local o_killer = self.o_killer
		for _, o in order do
			self:_nuke_troops(o, n.kind, lost[o], before[o])
			if o_tiles[o] <= 0 then
				o_killer[o] = n.owner
			end
			if o ~= n.owner then
				self:add_grudge(o, n.owner, Rules.NUKE_GRUDGE_TICKS)
			end
		end
		-- Structures and units inside the outer radius are destroyed.
		local r = math.ceil(radius)
		local r2 = radius * radius
		local o_name = self.o_name
		for _, s in self:structs_in_box(to, self.geo_span(to, radius), r) do
			if not s.dead and range_d2(to, s.tile) <= r2 then
				local so = s.owner
				self:destroy_struct(s)
				if so ~= n.owner then
					self:msg(
						so,
						Defs.MSG_BAD,
						string.format("%s destroyed your %s", o_name[n.owner], Defs.STRUCT_TITLES[s.kind])
					)
				end
			end
		end
		for _, u in self.unit_list do
			if u.dead then
				continue
			end
			local ut = self:unit_tile(u)
			if ut >= 0 and range_d2(to, ut) <= r2 then
				self:remove_unit(u, Defs.DEL_DESTROYED)
			end
		end
		self:ev({ Ev.BOOM, n.uid, n.kind, to, r, n.owner })
		local victim = n.target_owner
		if victim > 0 and n.kind ~= N_WARHEAD then
			self:msg(
				victim,
				Defs.MSG_BAD,
				string.format("%s from %s hit your land", cap_first(a_an(nuke_title(n.kind))), o_name[n.owner])
			)
		end
		if n.kind == N_HYDROGEN then
			self:msg_others(
				victim,
				Defs.MSG_INFO,
				string.format("Hydrogen bomb detonated over %s", self:name_of(victim))
			)
		end
	end

	-- nukeDeathFactor applied once per full-size tile lost: bombs remove 5 x troops / tiles left each
	-- time (so troops shrink by ((T - n) / T)^5), warheads 500 x (1 - e^(-2 excess / max)).
	function C:_nuke_troops(o: number, kind: number, n_lost: number, tiles_before: number)
		local cap = math.max(self.o_cap[o], 1.0)
		local o_troops = self.o_troops
		local dbg_flow = self.dbg_flow
		if kind ~= N_WARHEAD then
			local f = (math.max(0.0, tiles_before - n_lost) / math.max(tiles_before, 1)) ^ 5.0
			dbg_flow[o * 5 + 3] += o_troops[o] * (1.0 - f)
			o_troops[o] *= f
			for _, a in self.attacks do
				if not a.dead and a.attacker == o then
					a.troops *= f
				end
			end
			for _, u in self.unit_list do
				if not u.dead and u.owner == o and u.kind == U_TRANSPORT then
					u.troops *= f
				end
			end
			return
		end
		local k = self.R.K_AREA
		local warhead_death = Rules.warhead_death
		for _ = 1, n_lost do
			local d = math.min(k * warhead_death(o_troops[o], cap), math.max(0.0, o_troops[o] - 0.03 * cap))
			dbg_flow[o * 5 + 3] += d
			o_troops[o] -= d
		end
		for _, a in self.attacks do
			if not a.dead and a.attacker == o then
				for _ = 1, n_lost do
					a.troops -= math.min(k * warhead_death(a.troops, cap), math.max(0.0, a.troops - 0.03 * cap))
				end
			end
		end
		for _, u in self.unit_list do
			if not u.dead and u.owner == o and u.kind == U_TRANSPORT then
				for _ = 1, n_lost do
					u.troops -= math.min(k * warhead_death(u.troops, cap), math.max(0.0, u.troops - 0.03 * cap))
				end
			end
		end
	end

	function C:nuke_rows(): { { number } }
		local out = {}
		for _, n in self.nukes do
			if not n.dead then
				table.insert(out, { n.uid, n.kind, n.owner, n.from_tile, n.to_tile, n.launch_tick, n.flight })
			end
		end
		return out
	end
end

function SimNukes._mirv_mark(grid: { [number]: { number } }, W: number, t: number, gap: number)
	local k = ((t // W) // gap) * 65536 + ((t % W) // gap)
	local cell = grid[k]
	if cell == nil then
		cell = {}
		grid[k] = cell
	end
	table.insert(cell, t)
end

function SimNukes._mirv_overlaps(
	grid: { [number]: { number } },
	W: number,
	t: number,
	gap: number,
	geo_manhattan: (number, number) -> number
): boolean
	local gx = (t % W) // gap
	local gy = (t // W) // gap
	for dy = -1, 1 do
		for dx = -1, 1 do
			if gx + dx < 0 or gy + dy < 0 then
				continue
			end
			local cell = grid[(gy + dy) * 65536 + (gx + dx)]
			if cell == nil then
				continue
			end
			for _, o in cell do
				if geo_manhattan(o, t) < gap then
					return true
				end
			end
		end
	end
	return false
end

return SimNukes
