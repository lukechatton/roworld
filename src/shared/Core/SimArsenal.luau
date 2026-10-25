--!native
-- The Arsenal (2026-10-04): units such as Artillery and special nukes, each earned with the
-- in-game currency or bought with Robux. A mixin of the flattened Sim class, after
-- SimNukes. What a player may use is a bit mask per owner (Sim.o_unlock, Defs.UNLOCK; the match's host
-- sets it from the player's saved unlocks with Sim.set_unlocks): without the bit the Sim refuses the
-- build, the launch or the call. The AI builds none of it.
--
--   Artillery (structure)  shells whatever isn't its owner's or an ally's within range, on its own
--   Airfield (structure)   flies an air strike at a tile within range, then rearms
--   Railgun (structure)    fires a slug at any tile on the map, then reloads
--   Mega Nuke (silo)       an atom bomb with twice the radii
--   Scattershot (silo)     an atom bomb's crater, and 4 to 6 warheads around it
--   Reinforcements (call)  gold for a fifth of the troop cap
--   Rapid Reload           every reload of its owner's takes half as long
--
-- Shells, air strikes and slugs are munitions like the bombs (SimNukes: the same list, the same NUKE /
-- BOOM events, a straight flight path), but they land as a strike (_strike): they take no land and
-- leave no fallout. A strike kills a share of each army with land under it and damages the structures
-- there, never its owner's or an ally's. Structures have health only for this (Rules.STRUCT_HP): at 0
-- one loses a level and is whole again, or is destroyed at level 1.

local Defs = require("./Defs")
local Ev = require("./Ev")
local Rules = require("./Rules")
local SimState = require("./SimState")

local readi32 = buffer.readi32
local readu8 = buffer.readu8

local filled = SimState.filled
local a_an = SimState.a_an
local MAXO = Defs.MAX_OWNERS
local STRUCT_KINDS = SimState.STRUCT_KINDS

local S_SAM = Defs.S_SAM
local S_SILO = Defs.S_SILO
local S_ARTILLERY = Defs.S_ARTILLERY
local U_TRANSPORT = Defs.U_TRANSPORT
local N_WARHEAD = Defs.N_WARHEAD
local N_SCATTER = Defs.N_SCATTER
local N_SHELL = Defs.N_SHELL
local N_AIRSTRIKE = Defs.N_AIRSTRIKE
local N_SLUG = Defs.N_SLUG
local UNLOCK = Defs.UNLOCK

local SimArsenal = {}

--- What a locked build / launch / call tells the player (the client offers the unlock itself).
SimArsenal.LOCKED_TEXT = "Unlock %s in the Arsenal first"

function SimArsenal.install(C)
	function C:_init_arsenal()
		--- Defs.UNLOCK bits per owner.
		self.o_unlock = filled(MAXO, 0)
		--- Tick of each owner's last Reinforcements call.
		self.o_reinforce_tick = filled(MAXO, -100000)
		--- Finished batteries, in the order they finished.
		self.batteries = {} :: { any }
	end

	--- The Arsenal unlocks `id` plays with (a Defs.UNLOCK bit mask), from now on.
	function C:set_unlocks(id: number, mask: number)
		if id > 0 and id < MAXO and type(mask) == "number" and mask == mask then
			self.o_unlock[id] = bit32.band(math.max(0, math.floor(mask)), Defs.UNLOCK_ALL)
		end
	end

	function C:has_unlock(id: number, bit: number): boolean
		return bit == 0 or bit32.band(self.o_unlock[id] or 0, bit) ~= 0
	end

	--- Neither `a`'s own nor an ally's: what a strike may hurt.
	function C:_strike_enemy(a: number, b: number): boolean
		return b > 0 and b ~= a and not self:allied(a, b)
	end

	--- The tick to record for a shot `s` fires now (its `shots` queue: a shot reloads until that tick
	--- + Rules.RELOAD_TICKS). With Rapid Reload the shot is recorded as fired earlier, so everything
	--- that reads the queue (the Sim, the mirror's reload bar) needs only the kind's own reload time.
	function C:shot_stamp(s: any): number
		local tick = self.tick
		if bit32.band(self.o_unlock[s.owner] or 0, UNLOCK.reload2x) == 0 then
			return tick
		end
		local base = Rules.RELOAD_TICKS[s.kind] or 0
		return tick - (base - math.max(1, math.ceil(base * Rules.RAPID_RELOAD_MULT)))
	end

	-- =========================================================================================
	-- Structure health
	-- =========================================================================================

	--- `dmg` to structure `s` from owner `by`: at 0 health it loses a level (and is whole again) or,
	--- at level 1, is destroyed.
	function C:damage_struct(s: any, dmg: number, by: number)
		if s.dead or dmg <= 0 then
			return
		end
		local full = Rules.STRUCT_HP[s.kind] or 1000
		s.hp = (s.hp or full) - dmg
		if s.hp > 0 then
			return
		end
		local owner = s.owner
		local title = Defs.STRUCT_TITLES[s.kind]
		if s.level <= 1 then
			self:destroy_struct(s)
			self:msg(owner, Defs.MSG_BAD, string.format("%s destroyed your %s", self:name_of(by), title))
			return
		end
		s.level -= 1
		s.hp = full
		local b = owner * STRUCT_KINDS + s.kind
		self.o_slevel[b] -= 1
		if s.active then
			self.o_alevel[b] -= 1
		end
		self:ev({ Ev.STRUCT_LEVEL, s.sid, s.level, s.active_tick })
		-- a SAM or silo loses a missile slot: one still reloading goes first
		if (s.kind == S_SAM or s.kind == S_SILO) and #s.shots > s.level then
			while #s.shots > s.level do
				table.remove(s.shots)
			end
			self:ev({ Ev.STRUCT_SHOTS, s.sid, table.clone(s.shots) })
		end
		self:msg(
			owner,
			Defs.MSG_BAD,
			string.format("%s knocked your %s down to level %d", self:name_of(by), title, s.level)
		)
	end

	-- =========================================================================================
	-- Artillery
	-- =========================================================================================

	--- A finished battery starts its first gap (SimStructures._activate).
	function C:_battery_ready(s: any)
		s.next_fire = self.tick + self:_battery_gap(s)
		table.insert(self.batteries, s)
	end

	function C:_battery_gap(s: any): number
		local gap = self.rng:randi_range(Rules.ARTILLERY_GAP_MIN, Rules.ARTILLERY_GAP_MAX)
		if bit32.band(self.o_unlock[s.owner] or 0, UNLOCK.reload2x) ~= 0 then
			gap = math.max(1, math.ceil(gap * Rules.RAPID_RELOAD_MULT))
		end
		return gap
	end

	--- Where battery `s` aims: the nearest structure in range that isn't its owner's or an ally's,
	--- else enemy land found by a few random looks over its range. -1: nothing.
	function C:_battery_target(s: any): number
		local R = self.R
		local id = s.owner
		local range = R.artillery_range()
		local r2 = range * range
		local range_d2 = self.range_d2
		local best = -1
		local bd = 0.0
		for _, st in self:structs_in_box(s.tile, self.geo_span(s.tile, range), math.ceil(range)) do
			if st.dead or not self:_strike_enemy(id, st.owner) then
				continue
			end
			local d = range_d2(s.tile, st.tile)
			if d <= r2 and (best < 0 or d < bd or (d == bd and st.tile < best)) then
				best = st.tile
				bd = d
			end
		end
		if best >= 0 then
			return best
		end
		local W, H = self.W, self.H
		local cx, cy = s.tile % W, s.tile // W
		local owner = self.owner
		local land = self.land
		local rng = self.rng
		for _ = 1, Rules.ARTILLERY_SAMPLES do
			local ang = rng:randf() * 2.0 * math.pi
			local rad = range * math.sqrt(rng:randf())
			local x = math.floor(cx + math.cos(ang) * rad + 0.5)
			local y = math.floor(cy + math.sin(ang) * rad + 0.5)
			if x < 0 or y < 0 or x >= W or y >= H then
				continue
			end
			local t = y * W + x
			if readu8(land, t) == 1 and self:_strike_enemy(id, readi32(owner, t * 4)) then
				return t
			end
		end
		return -1
	end

	--- Batteries whose gap is over fire a shell (or look again in a moment).
	function C:arsenal_tick()
		local list = self.batteries
		local n = #list
		if n == 0 then
			return
		end
		local tick = self.tick
		local R = self.R
		local w = 0
		for i = 1, n do
			local s = list[i]
			if s.dead then
				continue
			end
			w += 1
			list[w] = s
			if tick < s.next_fire then
				continue
			end
			local t = self:_battery_target(s)
			if t < 0 then
				s.next_fire = tick + Rules.ARTILLERY_IDLE_TICKS
				continue
			end
			s.next_fire = tick + self:_battery_gap(s)
			local arc = R.munition_arc(self.W, self.H, s.tile, t, N_SHELL)
			self:_spawn_nuke(N_SHELL, s.owner, s.tile, t, R.nuke_arc_ticks(arc, N_SHELL), arc)
		end
		for i = n, w + 1, -1 do
			list[i] = nil
		end
	end

	-- =========================================================================================
	-- Strikes (a shell, an air strike or a slug lands)
	-- =========================================================================================

	function C:_strike(n: any)
		local kind = n.kind
		local to = n.to_tile
		local shooter = n.owner
		local R = self.R
		local range_d2 = self.range_d2
		local _, radius = R.nuke_radii(kind)
		local r2 = radius * radius
		local owner = self.owner
		-- land under the blast, per army that isn't the shooter's or an ally's (a shell: the tile it hits)
		local hit: { [number]: number } = {}
		local order = {}
		if kind == N_SHELL then
			local o = readi32(owner, to * 4)
			if self:_strike_enemy(shooter, o) then
				hit[o] = 1
				table.insert(order, o)
			end
		else
			for _, t in self:disk_tiles(to, radius, true) do
				local o = readi32(owner, t * 4)
				if self:_strike_enemy(shooter, o) then
					if hit[o] == nil then
						hit[o] = 0
						table.insert(order, o)
					end
					hit[o] += 1
				end
			end
		end
		local o_troops = self.o_troops
		local dbg_flow = self.dbg_flow
		local tick = self.tick
		for _, o in order do
			local troops = o_troops[o]
			local kill = Rules.strike_kill(kind, troops, hit[o] * R.K_AREA)
			if kill <= 0 then
				continue
			end
			local keep = 1.0 - kill / math.max(troops, 1.0)
			dbg_flow[o * 5 + 3] += kill
			o_troops[o] = troops - kill
			if kind ~= N_SHELL then
				-- the same share of its armies in the field and at sea
				for _, a in self.attacks do
					if not a.dead and a.attacker == o then
						a.troops *= keep
					end
				end
				for _, u in self.unit_list do
					if not u.dead and u.owner == o and u.kind == U_TRANSPORT then
						u.troops *= keep
					end
				end
				self:add_grudge(o, shooter, Rules.HOSTILE_TICKS)
				self.o_attacked_tick[o] = tick
			end
		end
		local dmg = Rules.STRIKE_DAMAGE[kind] or 0
		if dmg > 0 then
			local r = math.max(1, math.ceil(radius))
			for _, s in self:structs_in_box(to, math.max(1, self.geo_span(to, radius)), r) do
				if not s.dead and self:_strike_enemy(shooter, s.owner) and range_d2(to, s.tile) <= r2 then
					self:damage_struct(s, dmg, shooter)
				end
			end
		end
		self:ev({ Ev.BOOM, n.uid, kind, to, math.max(1, math.ceil(radius)), shooter })
		local victim = readi32(owner, to * 4)
		if kind ~= N_SHELL and self:_strike_enemy(shooter, victim) then
			self:msg(
				victim,
				Defs.MSG_BAD,
				string.format(
					"%s from %s hit your land",
					SimState.cap_first(a_an(Defs.NUKE_TITLES[kind])),
					self.o_name[shooter]
				)
			)
		end
	end

	-- =========================================================================================
	-- Scattershot
	-- =========================================================================================

	--- The warheads that leave the silo with a scattershot aimed at `aim`: Rules.SCATTER_MIN..MAX of
	--- them, evenly around the aim point (a random turn, a little jitter), SCATTER_NEAR..FAR tiles out,
	--- never onto `id`'s or an ally's land. Each lands a moment after the last.
	function C:_scatter_warheads(id: number, from_tile: number, aim: number, flight: number)
		local R = self.R
		local rng = self.rng
		local W, H = self.W, self.H
		local ax, ay = aim % W, aim // W
		local owner = self.owner
		local count = rng:randi_range(Rules.SCATTER_MIN, Rules.SCATTER_MAX)
		local base = rng:randf() * 2.0 * math.pi
		local near, far = Rules.SCATTER_NEAR_FULL / R.K_LIN, Rules.SCATTER_FAR_FULL / R.K_LIN
		local fired = 0
		for i = 0, count - 1 do
			local t = -1
			for _ = 1, 6 do
				local ang = base + i * 2.0 * math.pi / count + rng:randf_range(-0.3, 0.3)
				local rad = rng:randf_range(near, far)
				local x = math.floor(ax + math.cos(ang) * rad + 0.5)
				local y = math.floor(ay + math.sin(ang) * rad + 0.5)
				if x < 0 or y < 0 or x >= W or y >= H then
					continue
				end
				local c = y * W + x
				local o = readi32(owner, c * 4)
				if o == id or (o ~= 0 and self:allied(id, o)) then
					continue
				end
				t = c
				break
			end
			if t < 0 then
				continue
			end
			fired += 1
			local arc = R.nuke_arc(W, H, from_tile, t)
			local wn = self:_spawn_nuke(
				N_WARHEAD,
				id,
				from_tile,
				t,
				math.max(flight, R.nuke_arc_ticks(arc, N_SCATTER)) + fired * 2,
				arc
			)
			wn.target_owner = readi32(owner, t * 4)
		end
	end

	-- =========================================================================================
	-- Reinforcements
	-- =========================================================================================

	--- Ticks until `id` may call Reinforcements again (0: now).
	function C:reinforce_wait(id: number): number
		return math.max(0, self.o_reinforce_tick[id] + Rules.REINFORCE_COOLDOWN_TICKS - self.tick)
	end

	--- Reinforcements intent: Rules.REINFORCE_COST gold for a fifth of the troop cap, never past it.
	function C:reinforce(id: number): boolean
		if not self:has_unlock(id, UNLOCK.reinforce) then
			self:msg(id, Defs.MSG_INFO, string.format(SimArsenal.LOCKED_TEXT, "Reinforcements"))
			return false
		end
		local wait = self:reinforce_wait(id)
		if wait > 0 then
			self:msg(
				id,
				Defs.MSG_INFO,
				string.format("Reinforcements are ready in %d s", math.ceil(wait / Rules.TICK_RATE))
			)
			return false
		end
		local troops = Rules.reinforce_troops(self.o_troops[id], self.o_cap[id])
		if troops <= 0 then
			self:msg(id, Defs.MSG_INFO, "Your army is already at its cap")
			return false
		end
		if self.o_gold[id] < Rules.REINFORCE_COST then
			self:msg(id, Defs.MSG_INFO, "Not enough gold for Reinforcements")
			return false
		end
		self.o_gold[id] -= Rules.REINFORCE_COST
		self.o_troops[id] += troops
		self.o_reinforce_tick[id] = self.tick
		self:ev({ Ev.REINFORCE, id, troops, self.tick + Rules.REINFORCE_COOLDOWN_TICKS })
		self._force_stats = true
		return true
	end
end

return SimArsenal
