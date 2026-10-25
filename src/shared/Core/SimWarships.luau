--!native
-- Port of scripts/core/sim_warships.gd (SimWarships, mixin of the flattened Sim class).
-- Warships, shells and naval combat — patrols, shelling, move orders and trade-ship capture,
-- in full-size-tile units (self.R.K_LIN).
--
-- A warship sails a water path (UNIT_PATH) at 1 full-size tile per tick (2 while chasing a trade ship).
-- Every tick it heals (near an own port / docked), runs the repair-retreat logic and fights: it
-- picks the best target within 130 full-size tiles (transport > warship > trade ship, then nearest; the
-- search runs every SCAN_TICKS), shells transports and warships while it keeps patrolling, and
-- hunts trade ships down to capture them. Shells are projectiles: SHELL announces the impact
-- tick, damage lands then (UNIT_HP), or the shell fizzles if its target is gone or became friendly.

local Defs = require("./Defs")
local Coop = require("../Net/Coop")
local Ev = require("./Ev")
local Rules = require("./Rules")
local SimStructures = require("./SimStructures")

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local readi32 = buffer.readi32

local Unit = SimStructures.Unit

local STRUCT_KINDS = 16
--- Ship grid cell size (tiles).
local GCELL = 32

local S_PORT = Defs.S_PORT
local S_DEFENSE = Defs.S_DEFENSE
local U_TRANSPORT = Defs.U_TRANSPORT
local U_TRADE = Defs.U_TRADE
local U_WARSHIP = Defs.U_WARSHIP
local U_TRUCK = Defs.U_TRUCK
local T_LAKE = Defs.T_LAKE

local SCAN_TICKS = 3
local SHIP_CELL = 32

local EMPTY = table.freeze({})

local SimWarships = {}
SimWarships.SCAN_TICKS = SCAN_TICKS
SimWarships.SHIP_CELL = SHIP_CELL

export type Shell = {
	id: number,
	kind: number, -- 0 warship, 1 defense post
	shooter: number,
	owner: number,
	target: number,
	from_tile: number,
	fire_tick: number,
	impact_tick: number,
	damage: number,
}

local Shell = {}
SimWarships.Shell = Shell

function Shell.new(): Shell
	return {
		id = 0,
		kind = 0,
		shooter = 0,
		owner = 0,
		target = 0,
		from_tile = 0,
		fire_tick = 0,
		impact_tick = 0,
		damage = 0,
	}
end

function SimWarships.install(C)
	function C:_init_warships()
		self.warship_list = {}
		self.shells = {} :: { Shell }
		self.next_shell_id = 1
		-- Water tiles 4-adjacent to land (trade ships there are safe from pirates); built once per
		-- map and shared.
		local map = self.map
		local shore_water = map._shore_water
		if shore_water == nil then
			shore_water = SimWarships.shore_water(map)
			map._shore_water = shore_water
		end
		self.shore_water = shore_water
		self.defense_posts_shoot = Rules.DEFENSE_POST_SHOOTS
		-- uid → true, plus the uids in first-insertion order (GDScript Dictionary order).
		self._hp_dirty = {} :: { [number]: boolean }
		self._hp_dirty_list = {} :: { number }
		-- Ship positions bucketed in 32 x 32 tile cells (unit_list indices), rebuilt once per tick.
		local gw = (self.W + GCELL - 1) // GCELL
		local gh = (self.H + GCELL - 1) // GCELL
		self._ship_gw = gw
		local grid = table.create(gw * gh)
		for i = 1, gw * gh do
			grid[i] = {}
		end
		self._ship_grid = grid
		self._ship_pos = {} :: { number }
		self._ship_grid_tick = -1
		self._ship_cells_used = {} :: { number }
		-- (optimisation) reusable result list of _ships_near
		self._near_scratch = {} :: { number }
		self._post_last = {} :: { [number]: number }
		self._post_shelled = {} :: { [number]: boolean }
	end

	function C:_on_unit_added(u)
		if u.kind == U_WARSHIP then
			table.insert(self.warship_list, u)
		end
	end

	function C:_mark_hp(uid: number)
		if not self._hp_dirty[uid] then
			self._hp_dirty[uid] = true
			table.insert(self._hp_dirty_list, uid)
		end
	end

	-- =========================================================================================
	-- Building and orders
	-- =========================================================================================

	-- Warship spawn (same rule as Rules.warship_port on a GameState): from the nearest (manhattan)
	-- finished own port on the clicked water body (any body when land is clicked); it patrols
	-- around the clicked sea tile.
	function C:build_warship(id: number, t: number): boolean
		local geo_manhattan = self.geo_manhattan
		local map = self.map
		local body = -1
		if t >= 0 and t < self.N and readu8(map.terrain, t) <= T_LAKE then
			body = readu16(map.water_body, t * 2)
		end
		local best = nil
		local bd = 0.0
		local coast_body = map.coast_body
		for _, p in self.port_list do
			if p.owner ~= id or p.water < 0 or (body >= 0 and readu16(coast_body, p.tile * 2) ~= body) then
				continue
			end
			local d = if t >= 0 and t < self.N then geo_manhattan(t, p.tile) else 0.0
			if best == nil or d < bd or (d == bd and p.tile < best.tile) then
				bd = d
				best = p
			end
		end
		if best == nil then
			self:msg(id, Defs.MSG_INFO, "You need a port on that sea to build warships")
			return false
		end
		local cost = Rules.build_cost(
			Rules.WARSHIP_KIND_NAME,
			math.min(self.o_warships[id], self.o_built[id * STRUCT_KINDS + Rules.BUILT_WARSHIP])
		)
		if self.o_gold[id] < cost then
			self:msg(id, Defs.MSG_INFO, "Not enough gold for a Warship")
			return false
		end
		self.o_gold[id] -= cost
		local nav = self.nav
		local tick = self.tick
		local u = Unit.new()
		u.kind = U_WARSHIP
		u.owner = id
		u.path = { best.water }
		u.start_tick = tick
		u.tpt = self.R.WARSHIP_TPT_X100
		u.end_tick = tick
		u.max_hp = Rules.warship_max_hp(0)
		u.hp = u.max_hp
		u.body = readu16(nav.body, best.water * 2)
		u.patrol = best.water
		u.shelled = {}
		u.shelled_n = 0
		if body >= 0 and readu16(nav.body, t * 2) == u.body and readi32(nav.region, t * 4) >= 0 then
			u.patrol = t
		end
		self.o_warships[id] += 1
		self.o_built[id * STRUCT_KINDS + Rules.BUILT_WARSHIP] += 1
		self:add_unit(u)
		self:ev({ Ev.UNIT_HP, u.uid, u.hp, u.max_hp })
		self:_emit_state(u)
		return true
	end

	-- Move order: a new patrol tile for one of `id`'s warships (water on the same body).
	-- It also suspends repair retreats for WARSHIP_MANUAL_NO_RETREAT_TICKS and cancels one under way.
	function C:move_warship(id: number, uid: number, t: number): boolean
		local u = self.units[uid]
		if u == nil or u.dead or u.kind ~= U_WARSHIP or u.owner ~= id then
			return false
		end
		local nav = self.nav
		if t < 0 or t >= self.N or readu8(self.map.terrain, t) > T_LAKE or readi32(nav.region, t * 4) < 0 then
			return false
		end
		if readu16(nav.body, t * 2) ~= readu16(nav.body, self:unit_tile(u) * 2) then
			return false
		end
		u.patrol = t
		u.manual_tick = self.tick
		u.target_tile = -1
		if u.state ~= 0 then
			u.state = 0
			u.retreat_port = 0
			u.heal_rem = 0.0
		end
		self:_emit_state(u)
		return true
	end

	function C:_emit_state(u)
		self:ev({ Ev.UNIT_STATE, u.uid, u.state, u.patrol })
	end

	-- Sends `u` along a fresh water path to `dest` at `tpt`; false when there is no path.
	function C:_set_course(u, dest: number, tpt: number): boolean
		local pos = self:unit_tile(u)
		local p = self.nav:short_path(pos, dest)
		if #p < 2 then
			return false
		end
		local tick = self.tick
		u.path = p
		u.start_tick = tick
		u.tpt = tpt
		u.end_tick = tick + ((#p - 1) * tpt + 99) // 100
		self:ev({ Ev.UNIT_PATH, u.uid, p, tick, tpt })
		return true
	end

	function C:_stop(u)
		local pos = self:unit_tile(u)
		local tick = self.tick
		u.path = { pos }
		u.start_tick = tick
		u.end_tick = tick
		self:ev({ Ev.UNIT_PATH, u.uid, u.path, tick, u.tpt })
	end

	-- =========================================================================================
	-- Per tick
	-- =========================================================================================

	function C:warships_tick()
		local list = self.warship_list
		if #list > 0 then
			local n = #list
			for i = 1, n do
				local u = list[i]
				if not u.dead then
					self:_warship_tick(u)
				end
				if i % 8 == 0 then
					Coop.check() -- (a local match's step is spread over frames: Session._local_process)
				end
			end
			local w = 0
			local m = #list
			for i = 1, m do
				local u2 = list[i]
				if not u2.dead then
					w += 1
					list[w] = u2
				end
			end
			for i = m, w + 1, -1 do
				list[i] = nil
			end
		end
		if self.defense_posts_shoot and self.tick % 10 == 0 then
			self:_posts_tick()
		end
		if #self.shells > 0 then
			self:_shells_tick()
		end
		local dl = self._hp_dirty_list
		if #dl > 0 then
			local units = self.units
			for _, uid in dl do
				local u3 = units[uid]
				if u3 ~= nil and not u3.dead then
					self:ev({ Ev.UNIT_HP, uid, u3.hp, u3.max_hp })
				end
			end
			table.clear(dl)
			table.clear(self._hp_dirty)
		end
	end

	function C:_warship_tick(u)
		if self.o_alive[u.owner] == 0 then
			self:remove_unit(u, Defs.DEL_DESTROYED)
			return
		end
		local pos = self:unit_tile(u)
		local hp_before = u.hp
		self:_heal(u, pos)
		if u.state == 2 then
			local port = self.structs[u.retreat_port]
			if port == nil or port.owner ~= u.owner or u.hp >= u.max_hp then
				self:_cancel_retreat(u)
			end
			if u.state == 2 then
				return
			end
		end
		if self:_handle_retreat(u, pos) then
			return
		end
		if self:_should_retreat(u, hp_before) then
			self:_start_retreat(u, pos)
			if self:_handle_retreat(u, pos) then
				return
			end
		end
		local tgt = nil
		if (self.tick + u.uid) % SCAN_TICKS == 0 then
			tgt = self:_find_target(u, pos, true)
			u.target_uid = if tgt ~= nil then tgt.uid else 0
		elseif u.target_uid ~= 0 then
			tgt = self.units[u.target_uid]
			if tgt == nil or tgt.dead or tgt.owner == u.owner or self:allied(tgt.owner, u.owner) then
				tgt = nil
				u.target_uid = 0
			end
		end
		if tgt ~= nil and tgt.kind ~= U_TRADE then
			self:_shoot(u, tgt, pos)
			self:_patrol(u)
			return
		end
		if tgt ~= nil then
			self:_hunt(u, tgt, pos)
			return
		end
		if u.hunt_uid ~= 0 then
			u.hunt_uid = 0
			u.target_tile = -1
		end
		self:_patrol(u)
	end

	-- Passive +1 HP/tick near an own port; docked ships share the port's level x 5 HP/tick.
	function C:_heal(u, pos: number)
		local range_d2 = self.range_d2
		local tick = self.tick
		if tick >= u.near_port_tick then
			u.near_port_tick = tick + 10
			u.near_port = false
			local r = Rules.WARSHIP_PASSIVE_HEAL_FULL / self.R.K_LIN
			local r2 = r * r
			for _, p in self.port_list do
				if p.owner == u.owner and range_d2(pos, p.tile) <= r2 then
					u.near_port = true
					break
				end
			end
		end
		local before = u.hp
		if u.near_port then
			u.hp = math.min(u.max_hp, u.hp + Rules.WARSHIP_PASSIVE_HEAL)
		end
		if u.state == 2 then
			local port = self.structs[u.retreat_port]
			if port ~= nil then
				local docked = self:_docked_at(port, nil)
				if docked > 0 then
					u.heal_rem += (port.level * Rules.WARSHIP_PORT_HEAL_PER_LEVEL) / docked
					local add = math.floor(u.heal_rem)
					if add > 0 then
						u.heal_rem -= add
						u.hp = math.min(u.max_hp, u.hp + add)
					end
				end
			end
		end
		if u.hp ~= before then
			self:_mark_hp(u.uid)
		end
	end

	function C:_patrol(u)
		if u.target_tile >= 0 and self.tick < u.end_tick then
			return
		end
		local pos = self:unit_tile(u)
		local t = self:_random_patrol_tile(u, pos, false)
		if t < 0 then
			t = self:_random_patrol_tile(u, pos, true)
		end
		if t < 0 or not self:_set_course(u, t, self.R.WARSHIP_TPT_X100) then
			u.target_tile = -1
			return
		end
		u.target_tile = t
	end

	-- Random patrol tile: a water tile of the ship's body within warshipPatrolRange / 2
	-- of its patrol tile (not on the shoreline unless nothing else is found; the box widens 1.5x
	-- up to three times).
	function C:_random_patrol_tile(u, pos: number, allow_shore: boolean): number
		local pt = if u.patrol >= 0 then u.patrol else pos
		local half = Rules.WARSHIP_PATROL_FULL / self.R.K_LIN / 2.0
		local nav = self.nav
		local nbody = nav.body
		local region = nav.region
		local terrain = self.map.terrain
		local shore_water = self.shore_water
		local rng = self.rng
		local bd = readu16(nbody, pos * 2)
		local W = self.W
		local H = self.H
		local cx = pt % W
		local cy = pt // W
		for _ = 1, 4 do
			local hy = Defs.trunc(half)
			local hx = self.geo_span(pt, half)
			for _ = 1, 40 do
				local x = cx + rng:randi_range(-hx, hx)
				local y = cy + rng:randi_range(-hy, hy)
				if y < 1 or y >= H - 1 or x < 0 or x >= W then
					continue
				end
				local t = y * W + x
				if readu8(terrain, t) > T_LAKE or readu16(nbody, t * 2) ~= bd or readi32(region, t * 4) < 0 then
					continue
				end
				if not allow_shore and readu8(shore_water, t) == 1 then
					continue
				end
				return t
			end
			half *= 1.5
		end
		return -1
	end

	-- =========================================================================================
	-- Targets and shells
	-- =========================================================================================

	function C:_build_ship_grid()
		local tick = self.tick
		self._ship_grid_tick = tick
		local grid = self._ship_grid
		-- (optimisation) only the cells filled last time need clearing
		local used = self._ship_cells_used
		for k = 1, #used do
			table.clear(grid[used[k]])
		end
		table.clear(used)
		local list = self.unit_list
		local n = #list
		local ship_pos = self._ship_pos
		local W = self.W
		local gw = self._ship_gw
		for i = 1, n do
			local u = list[i]
			if u.dead or u.kind == U_TRUCK then
				ship_pos[i] = -1
				continue
			end
			-- inlined unit_tile(u)
			local path = u.path
			local np = #path
			local p = -1
			if np > 0 then
				local tpt = u.tpt
				if tpt < 1 then
					tpt = 1
				end
				local idx = (tick - u.start_tick) * 100 // tpt
				if idx < 0 then
					idx = 0
				elseif idx > np - 1 then
					idx = np - 1
				end
				p = path[idx + 1]
			end
			ship_pos[i] = p
			if p >= 0 then
				local ci = ((p // W) // GCELL) * gw + (p % W) // GCELL + 1
				local cell = grid[ci]
				local m = #cell
				if m == 0 then
					used[#used + 1] = ci
				end
				cell[m + 1] = i
			end
		end
		for i = #ship_pos, n + 1, -1 do
			ship_pos[i] = nil
		end
	end

	-- Unit-list indices of ships within `r` tiles (box) of `pos`. Returns a scratch list (reused by
	-- the next call; callers never nest) and its length.
	function C:_ships_near(pos: number, r: number): ({ number }, number)
		if self._ship_grid_tick ~= self.tick then
			self:_build_ship_grid()
		end
		local out = self._near_scratch
		local n = 0
		local W = self.W
		local gw = self._ship_gw
		local px = pos % W
		local py = pos // W
		local ri = math.ceil(r)
		local rx = self.geo_span(pos, r)
		local gy0 = math.max(py - ri, 0) // GCELL
		local gy1 = math.min(py + ri, self.H - 1) // GCELL
		local gx0 = math.max(px - rx, 0) // GCELL
		local gx1 = math.min(px + rx, W - 1) // GCELL
		local grid = self._ship_grid
		for gy = gy0, gy1 do
			for g = gx0, gx1 do
				local cell = grid[gy * gw + g + 1]
				for k = 1, #cell do
					n += 1
					out[n] = cell[k]
				end
			end
		end
		return out, n
	end

	-- Best target: non-allied ships within warshipTargettingRange, transport > warship >
	-- trade ship, then nearest; skips docked warships and one-shot targets already shelled.
	-- Trade ships only with a reachable own port, within patrol range of the patrol tile, not
	-- hugging a shore (safe from pirates) and not bound for an own / allied port.
	function C:_find_target(u, pos: number, include_trade: boolean)
		local range_d2 = self.range_d2
		local r = self.R.warship_range()
		local r2 = r * r
		local pr = Rules.WARSHIP_PATROL_FULL / self.R.K_LIN
		local reachable = -1
		local best = nil
		local bp = 9
		local bd = 0.0
		local list = self.unit_list
		local ship_pos = self._ship_pos
		local shelled = u.shelled or EMPTY
		local near, nn = self:_ships_near(pos, r)
		for k = 1, nn do
			local idx = near[k]
			local v = list[idx]
			if v.dead or v == u or v.owner == u.owner or self:allied(v.owner, u.owner) or shelled[v.uid] then
				continue
			end
			local pri = 0
			local vk = v.kind
			if vk == U_TRANSPORT then
				pri = 0
			elseif vk == U_WARSHIP then
				if v.state == 2 then
					continue
				end
				pri = 1
			elseif vk == U_TRADE then
				if not include_trade then
					continue
				end
				pri = 2
			else
				continue
			end
			if pri > bp then
				continue
			end
			local vt = ship_pos[idx]
			local d = range_d2(pos, vt)
			if d > r2 then
				continue
			end
			if pri == 2 then
				if reachable < 0 then
					reachable = if self:_own_port_on(u.owner, readu16(self.nav.body, pos * 2)) ~= nil then 1 else 0
				end
				if reachable == 0 or u.patrol < 0 or self:_safe_from_pirates(v) then
					continue
				end
				local dst = self.structs[v.dst_sid]
				if dst ~= nil and (dst.owner == u.owner or self:allied(dst.owner, u.owner)) then
					continue
				end
				if range_d2(u.patrol, vt) > pr * pr then
					continue
				end
			end
			if best == nil or pri < bp or (pri == bp and d < bd) then
				best = v
				bp = pri
				bd = d
			end
		end
		return best
	end

	function C:_own_port_on(id: number, water_body: number)
		local nbody = self.nav.body
		for _, p in self.port_list do
			if p.owner == id and p.water >= 0 and readu16(nbody, p.water * 2) == water_body then
				return p
			end
		end
		return nil
	end

	-- A trade ship that sailed a shoreline tile in the last SAFE_FROM_PIRATES_TICKS is safe.
	function C:_safe_from_pirates(v): boolean
		local path = v.path
		local n = #path
		if n == 0 then
			return false
		end
		local tpt = math.max(v.tpt, 1)
		local idx = math.clamp((self.tick - v.start_tick) * 100 // tpt, 0, n - 1)
		local back = Rules.SAFE_FROM_PIRATES_TICKS * 100 // tpt + 1
		local shore_water = self.shore_water
		for i = math.max(0, idx - back), idx do
			if readu8(shore_water, path[i + 1]) == 1 then
				return true
			end
		end
		return false
	end

	-- Shooting: every WARSHIP_FIRE_TICKS (no reload between transports); one shell per
	-- one-shot target.
	function C:_shoot(u, tgt, pos: number)
		local tick = self.tick
		if tick - u.last_shot <= Rules.WARSHIP_FIRE_TICKS then
			return
		end
		if tgt.kind ~= U_TRANSPORT then
			u.last_shot = tick
		end
		self:_fire(0, u.uid, u.owner, pos, tgt, u.vet)
		if tgt.kind ~= U_WARSHIP then
			local shelled = u.shelled
			if shelled == nil then
				shelled = {}
				u.shelled = shelled
				u.shelled_n = 0
			end
			if not shelled[tgt.uid] then
				shelled[tgt.uid] = true
				u.shelled_n += 1
			end
			u.target_uid = 0
			if u.shelled_n > 64 then
				local units = self.units
				for k in shelled do
					if units[k] == nil then
						shelled[k] = nil
						u.shelled_n -= 1
					end
				end
			end
		end
	end

	function C:_fire(kind: number, shooter: number, owner_id: number, from: number, tgt, vet: number)
		local range_d2 = self.range_d2
		local tick = self.tick
		local s = Shell.new()
		s.id = self.next_shell_id
		self.next_shell_id += 1
		s.kind = kind
		s.shooter = shooter
		s.owner = owner_id
		s.target = tgt.uid
		s.from_tile = from
		s.fire_tick = tick
		s.impact_tick = tick + self.R.shell_flight_ticks(math.sqrt(range_d2(from, self:unit_tile(tgt))))
		s.damage = Rules.shell_damage(self.rng:randi_range(1, 5), vet)
		table.insert(self.shells, s)
		self:ev({ Ev.SHELL, s.id, kind, shooter, from, tgt.uid, tick, s.impact_tick, s.damage })
	end

	function C:_shells_tick()
		local tick = self.tick
		local keep = {}
		local due = {}
		for _, s in self.shells do
			if s.impact_tick > tick then
				table.insert(keep, s)
			else
				table.insert(due, s)
			end
		end
		self.shells = keep
		local units = self.units
		for _, s in due do
			local t = units[s.target]
			if t == nil or t.dead or t.owner == s.owner then
				continue
			end
			self:_hit(s, t)
		end
	end

	function C:_hit(s: Shell, t)
		local o_name = self.o_name
		local who = if s.kind == 0
			then string.format("%s's warship", o_name[s.owner])
			else string.format("%s's defenses", o_name[s.owner])
		if t.kind == U_TRANSPORT then
			self:remove_unit(t, Defs.DEL_DESTROYED)
			self:msg(t.owner, Defs.MSG_BAD, string.format("%s sank your transport", who))
			if s.kind == 0 then
				self:msg(
					s.owner,
					Defs.MSG_GOOD,
					string.format("Your warship sank a transport from %s", o_name[t.owner])
				)
			end
			self:_record_kill(s, U_TRANSPORT)
			self:_on_transport_sunk(t, s.owner)
		elseif t.kind == U_WARSHIP then
			t.hp = math.max(0, t.hp - s.damage)
			self:_mark_hp(t.uid)
			if t.hp <= 0 then
				self:remove_unit(t, Defs.DEL_DESTROYED)
				self:msg(t.owner, Defs.MSG_BAD, string.format("%s sank your warship", who))
				self:msg(s.owner, Defs.MSG_GOOD, string.format("You sank a warship from %s", o_name[t.owner]))
				self:_record_kill(s, U_WARSHIP)
			end
		end
	end

	-- Veterancy: a warship's final blow on a warship is +1 veterancy at once (progress
	-- wiped); a transport adds WARSHIP_VET_TRADES points of the TRANSPORTS x TRADES per level.
	function C:_record_kill(s: Shell, kind: number)
		if s.kind ~= 0 then
			return
		end
		local w = self.units[s.shooter]
		if w == nil or w.dead or w.kind ~= U_WARSHIP then
			return
		end
		if kind == U_WARSHIP then
			w.vet_progress = 0
			self:_vet_up(w)
		else
			self:_vet_progress(w, Rules.WARSHIP_VET_TRADES)
		end
	end

	function C:_vet_progress(w, points: number)
		local max_vet = Rules.WARSHIP_MAX_VET
		if w.vet >= max_vet then
			return
		end
		local per_level = Rules.WARSHIP_VET_TRANSPORTS * Rules.WARSHIP_VET_TRADES
		w.vet_progress += points
		while w.vet_progress >= per_level and w.vet < max_vet do
			w.vet_progress -= per_level
			self:_vet_up(w)
		end
		if w.vet >= max_vet then
			w.vet_progress = 0
		end
	end

	function C:_vet_up(w)
		if w.vet >= Rules.WARSHIP_MAX_VET then
			return
		end
		w.vet += 1
		w.max_hp = Rules.warship_max_hp(w.vet)
		self:_mark_hp(w.uid)
		self:ev({ Ev.UNIT_VET, w.uid, w.vet })
	end

	-- =========================================================================================
	-- Trade-ship hunting and capture
	-- =========================================================================================

	-- Trade-ship hunt: chase at 2 full-size tiles per tick; capture within warshipDockingRange
	-- (manhattan).
	function C:_hunt(u, tgt, pos: number)
		local geo_manhattan = self.geo_manhattan
		local tp = self:unit_tile(tgt)
		if geo_manhattan(pos, tp) <= Rules.WARSHIP_DOCK_FULL / self.R.K_LIN then
			self:_capture_trade(u, tgt, tp)
			u.target_uid = 0
			u.hunt_uid = 0
			u.target_tile = -1
			return
		end
		local tick = self.tick
		if u.hunt_uid ~= tgt.uid or tick - u.hunt_path_tick >= 10 or tick >= u.end_tick then
			u.hunt_uid = tgt.uid
			u.hunt_path_tick = tick
			u.target_tile = -2
			self:_set_course(u, tp, self.R.WARSHIP_HUNT_TPT_X100)
		end
	end

	-- The trade ship changes hands (UNIT_DEL "captured" + a new UNIT_ADD for the captor) and
	-- sails to the captor's nearest port on that water; its gold on arrival goes to the captor.
	function C:_capture_trade(u, v, vpos: number)
		local geo_manhattan = self.geo_manhattan
		local tick = self.tick
		local victim = v.owner
		local orig = if v.orig_owner ~= 0 then v.orig_owner else v.owner
		local tpt = math.max(v.tpt, 1)
		local sailed = v.traveled + math.clamp((tick - v.start_tick) * 100 // tpt, 0, math.max(#v.path - 1, 0))
		self:remove_unit(v, Defs.DEL_CAPTURED)
		self:_vet_progress(u, Rules.WARSHIP_VET_TRANSPORTS)
		local last = self._capture_msg_tick[victim]
		if tick - (if last == nil then -1000 else last) > 150 then
			self._capture_msg_tick[victim] = tick
			self:msg(
				victim,
				Defs.MSG_BAD,
				string.format("%s's warships are capturing your trade ships", self.o_name[u.owner])
			)
		end
		self:msg(
			u.owner,
			Defs.MSG_GOOD,
			string.format("Your warship captured a trade ship from %s", self.o_name[victim])
		)
		self:_on_trade_captured(victim, u.owner, vpos)
		local best = nil
		local bd = 0.0
		local nav = self.nav
		local nbody = nav.body
		local water = readu16(nbody, vpos * 2)
		for _, p in self.port_list do
			if p.owner ~= u.owner or p.water < 0 or readu16(nbody, p.water * 2) ~= water then
				continue
			end
			local d = geo_manhattan(vpos, p.tile)
			if best == nil or d < bd then
				best = p
				bd = d
			end
		end
		if best == nil then
			return
		end
		local path = nav:find_path(vpos, best.water)
		if #path < 2 then
			return
		end
		local w = Unit.new()
		w.kind = U_TRADE
		w.owner = u.owner
		w.path = path
		w.start_tick = tick
		w.tpt = self.R.TRADE_TPT_X100
		w.src_sid = v.src_sid
		w.dst_sid = best.sid
		w.body = v.body
		w.orig_owner = orig
		w.traveled = sailed
		w.end_tick = tick + ((#path - 1) * w.tpt + 99) // 100
		self:add_unit(w)
	end

	-- =========================================================================================
	-- Repair retreat and docking
	-- =========================================================================================

	function C:_should_retreat(u, hp_before: number): boolean
		if u.state ~= 0 or self.tick - u.manual_tick < Rules.WARSHIP_MANUAL_NO_RETREAT_TICKS then
			return false
		end
		if hp_before >= u.max_hp * Rules.WARSHIP_RETREAT_PCT // 100 then
			return false
		end
		return self.o_scount[u.owner * STRUCT_KINDS + S_PORT] > 0
	end

	function C:_start_retreat(u, pos: number)
		local p = self:_nearest_port(u, pos, false, nil)
		if p == nil then
			return
		end
		u.state = 1
		u.retreat_port = p.sid
		u.heal_rem = 0.0
		u.target_uid = 0
		u.hunt_uid = 0
		u.port_check_tick = self.tick + 10
		self:_emit_state(u)
	end

	function C:_cancel_retreat(u)
		u.state = 0
		u.retreat_port = 0
		u.heal_rem = 0.0
		u.target_tile = -1
		self:_emit_state(u)
	end

	-- Repair retreat: fire back at transports / warships in range, head for the retreat port
	-- (switching to a free or much nearer one), dock when within warshipDockingRange if the port
	-- has room (a port docks `level` ships).
	function C:_handle_retreat(u, pos: number): boolean
		local range_d2 = self.range_d2
		if u.state == 0 then
			return false
		end
		if (self.tick + u.uid) % SCAN_TICKS == 0 then
			local aggro = self:_find_target(u, pos, false)
			if aggro ~= nil then
				self:_shoot(u, aggro, pos)
			end
		end
		if not self:_refresh_retreat_port(u, pos) then
			self:_cancel_retreat(u)
			return false
		end
		local port = self.structs[u.retreat_port]
		local dock = Rules.WARSHIP_DOCK_FULL / self.R.K_LIN
		if range_d2(pos, port.tile) <= dock * dock then
			if self:_docked_at(port, u) < port.level then
				u.state = 2
				self:_stop(u)
				self:_emit_state(u)
				return true
			end
			if u.hp >= u.max_hp then
				self:_cancel_retreat(u)
				return false
			end
			return true
		end
		if u.target_tile ~= port.water or self.tick >= u.end_tick then
			if self:_set_course(u, port.water, self.R.WARSHIP_TPT_X100) then
				u.target_tile = port.water
			else
				local alt = self:_nearest_port(u, pos, true, u)
				if alt == nil or alt == port then
					self:_cancel_retreat(u)
					return false
				end
				u.retreat_port = alt.sid
			end
		end
		return true
	end

	function C:_refresh_retreat_port(u, pos: number): boolean
		local range_d2 = self.range_d2
		if self.o_scount[u.owner * STRUCT_KINDS + S_PORT] <= 0 then
			return false
		end
		local cur = self.structs[u.retreat_port]
		if cur == nil or cur.dead or cur.owner ~= u.owner or not cur.active then
			local np = self:_nearest_port(u, pos, true, u)
			u.retreat_port = if np ~= nil then np.sid else 0
			return np ~= nil
		end
		local tick = self.tick
		if tick < u.port_check_tick then
			return true
		end
		u.port_check_tick = tick + 10
		if self:_docked_at(cur, nil) >= cur.level then
			local alt = self:_nearest_port(u, pos, true, nil)
			if alt ~= nil then
				u.retreat_port = alt.sid
			end
			return true
		end
		local better = self:_nearest_port(u, pos, true, nil)
		if
			better ~= nil
			and better ~= cur
			and range_d2(pos, better.tile) < range_d2(pos, cur.tile) * Rules.WARSHIP_PORT_SWITCH
		then
			u.retreat_port = better.sid
		end
		return true
	end

	-- Nearest own finished port on the ship's water (optionally only ports with docking room).
	function C:_nearest_port(u, pos: number, available: boolean, exclude)
		local range_d2 = self.range_d2
		local nbody = self.nav.body
		local water = readu16(nbody, pos * 2)
		local best = nil
		local bd = 0.0
		for _, p in self.port_list do
			if p.owner ~= u.owner or p.water < 0 or readu16(nbody, p.water * 2) ~= water then
				continue
			end
			if available and self:_docked_at(p, exclude) >= p.level then
				continue
			end
			local d = range_d2(pos, p.tile)
			if best == nil or d < bd then
				best = p
				bd = d
			end
		end
		return best
	end

	function C:_docked_at(port, exclude): number
		local n = 0
		local sid = port.sid
		local owner = port.owner
		for _, w in self.warship_list do
			if not w.dead and w ~= exclude and w.state == 2 and w.retreat_port == sid and w.owner == owner then
				n += 1
			end
		end
		return n
	end

	-- =========================================================================================
	-- Defense posts (off unless defense_posts_shoot)
	-- =========================================================================================

	function C:_posts_tick()
		local range_d2 = self.range_d2
		local r = Rules.DEFENSE_POST_TARGET_FULL / self.R.K_LIN
		local r2 = r * r
		local tick = self.tick
		local list = self.unit_list
		for _, s in self.struct_list do
			if s.kind ~= S_DEFENSE or not s.active or s.dead then
				continue
			end
			local last = self._post_last[s.sid]
			if tick - (if last == nil then -100000 else last) <= Rules.DEFENSE_POST_SHELL_TICKS then
				continue
			end
			local best = nil
			local bp = 9
			local bd = 0.0
			local near, nn = self:_ships_near(s.tile, r)
			for k = 1, nn do
				local idx = near[k]
				local v = list[idx]
				if v.dead or v.owner == s.owner or self:allied(v.owner, s.owner) then
					continue
				end
				if v.kind ~= U_TRANSPORT and v.kind ~= U_WARSHIP then
					continue
				end
				if self._post_shelled[s.sid * 1048576 + v.uid] then
					continue
				end
				local d = range_d2(s.tile, self._ship_pos[idx])
				if d > r2 then
					continue
				end
				local pri = if v.kind == U_TRANSPORT then 0 else 1
				if best == nil or pri < bp or (pri == bp and d < bd) then
					best = v
					bp = pri
					bd = d
				end
			end
			if best == nil then
				continue
			end
			self._post_last[s.sid] = tick
			self:_fire(1, s.sid, s.owner, s.tile, best, 0)
			if best.kind == U_TRANSPORT then
				self._post_shelled[s.sid * 1048576 + best.uid] = true
			end
		end
	end

	-- =========================================================================================
	-- Hooks (the Sim forwards them to the AI) and snapshot
	-- =========================================================================================

	function C:_on_transport_sunk(_u, _killer: number) end

	function C:_on_trade_captured(_victim: number, _captor: number, _tile: number) end

	function C:shell_rows(): { { number } }
		local out = {}
		for _, s in self.shells do
			table.insert(out, { s.id, s.kind, s.shooter, s.from_tile, s.target, s.fire_tick, s.impact_tick, s.damage })
		end
		return out
	end
end

--- u8 buffer: 1 on water tiles 4-adjacent to contestable land (the water shoreline).
function SimWarships.shore_water(map: any): buffer
	local W, N = map.W, map.N
	local shore = buffer.create(N)
	local terrain = map.terrain
	local coast_list = map.coast_list
	for k = 0, map.coast_count - 1 do
		local c = readi32(coast_list, k * 4)
		local x = c % W
		if x > 0 and readu8(terrain, c - 1) <= T_LAKE then
			writeu8(shore, c - 1, 1)
		end
		if x < W - 1 and readu8(terrain, c + 1) <= T_LAKE then
			writeu8(shore, c + 1, 1)
		end
		if c >= W and readu8(terrain, c - W) <= T_LAKE then
			writeu8(shore, c - W, 1)
		end
		if c < N - W and readu8(terrain, c + W) <= T_LAKE then
			writeu8(shore, c + W, 1)
		end
	end
	return shore
end

return SimWarships
