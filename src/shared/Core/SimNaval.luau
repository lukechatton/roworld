--!native
-- Port of scripts/core/sim_naval.gd (SimNaval, mixin of the flattened Sim class).
-- Transport boats (amphibious attacks) and trade ships between ports (warships: SimWarships).
-- Moving ships cost nothing per tick: their position is implicit from start_tick and speed;
-- only arrivals run logic.

local Defs = require("./Defs")
local Coop = require("../Net/Coop")
local Rules = require("./Rules")
local SimNav = require("./SimNav")
local SimStructures = require("./SimStructures")

local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readi32 = buffer.readi32

local Unit = SimStructures.Unit

local MAXO = Defs.MAX_OWNERS

local S_PORT = Defs.S_PORT
local U_TRANSPORT = Defs.U_TRANSPORT
local U_TRADE = Defs.U_TRADE
local U_TRUCK = Defs.U_TRUCK

-- (src_sid << 20) | dst_sid (sids stay far below 2^20)
local KEY_SHIFT = 1048576

local SimNaval = {}

function SimNaval.install(C)
	function C:_init_naval()
		self.nav = SimNav.shared(self.map)
		-- (src_sid << 20) | dst_sid → water tile path
		self.trade_cache = {} :: { [number]: { number } }
		-- Uncached trade routes that may still be computed this tick.
		self.path_budget = 0
		-- Tick of the last "trade ship captured" message per victim (throttles spam).
		self._capture_msg_tick = {} :: { [number]: number }
		-- Remaining boat path searches this second per owner (refilled by refill_boat_tokens()).
		local bt = table.create(MAXO)
		for i = 0, MAXO - 1 do
			bt[i] = Rules.BOAT_SEARCHES_PER_S
		end
		self.boat_tokens = bt
	end

	function C:refill_boat_tokens()
		local bt = self.boat_tokens
		local v = Rules.BOAT_SEARCHES_PER_S
		for i = 0, MAXO - 1 do
			bt[i] = v
		end
	end

	function C:_port_water(t: number, water_body: number): number
		return self.nav:water_next_to(t, water_body)
	end

	local super_destroy_struct = C.destroy_struct
	function C:destroy_struct(s)
		local was_port = s.kind == S_PORT and not s.dead
		super_destroy_struct(self, s)
		if was_port and next(self.trade_cache) ~= nil then
			local drop = {}
			local sid = s.sid
			for k in self.trade_cache do
				if k // KEY_SHIFT == sid or k % KEY_SHIFT == sid then
					table.insert(drop, k)
				end
			end
			for _, k in drop do
				self.trade_cache[k] = nil
			end
		end
	end

	-- =========================================================================================
	-- Transports
	-- =========================================================================================

	-- Boat intent: carry `ratio` of home troops to coastal tile `t` and attack from the beachhead.
	function C:launch_boat(id: number, t: number, ratio: number): boolean
		-- Cheap rejections first; the coast scan and path search are budgeted per owner.
		if not Defs.is_finite(ratio) or t < 0 or t >= self.N then
			return false
		end
		local map = self.map
		if readu8(self.land, t) == 0 or readu8(map.coastal, t) == 0 then
			self:msg(id, Defs.MSG_INFO, "Boats can only land on a coast")
			return false
		end
		local tg = readi32(self.owner, t * 4)
		if tg == id then
			return false
		end
		if tg ~= 0 and self:allied(id, tg) then
			self:msg(id, Defs.MSG_INFO, string.format("%s is your ally", self.o_name[tg]))
			return false
		end
		-- (a person: kind human and no bot; a bot player's AI holds itself to the AI's limit)
		if self.o_boats[id] >= Rules.max_boats(self.o_tiles[id], self.o_kind[id] == Defs.KIND_HUMAN and self.o_bot[id] ~= 1) then
			self:msg(id, Defs.MSG_INFO, "Too many transports at sea")
			return false
		end
		local r = math.clamp(ratio, 0.01, 1.0)
		if self.o_troops[id] * r < 1.0 then
			return false
		end
		if self.boat_tokens[id] <= 0 then
			self:msg(id, Defs.MSG_INFO, "Too many boat orders at once — wait a moment")
			return false
		end
		self.boat_tokens[id] -= 1
		local water_body = readu16(map.coast_body, t * 2)
		local src = self:nearest_own_coast(id, water_body, t)
		if src < 0 then
			self:msg(id, Defs.MSG_INFO, "You have no coast on that sea")
			return false
		end
		local nav = self.nav
		local ws = nav:water_next_to(src, water_body)
		local wd = nav:water_next_to(t, water_body)
		local path = nav:find_path(ws, wd)
		if #path < 2 then
			self:msg(id, Defs.MSG_INFO, "No sea route to that coast")
			return false
		end
		-- Launching the boat takes its troops from home (floored).
		local troops = math.floor(self.o_troops[id] * r)
		if troops < 1.0 then
			return false
		end
		self.o_troops[id] -= troops
		self.dbg_flow[id * 5 + 1] += troops
		local tick = self.tick
		local u = Unit.new()
		u.kind = U_TRANSPORT
		u.owner = id
		u.path = path
		u.start_tick = tick
		u.tpt = self.R.TRANSPORT_TPT_X100
		u.troops = troops
		u.target_tile = t
		u.body = water_body
		u.end_tick = tick + ((#path - 1) * u.tpt + 99) // 100
		self.o_boats[id] += 1
		self:add_unit(u)
		if tg ~= 0 then
			self:msg(tg, Defs.MSG_ALERT, string.format("%s sent a transport toward your coast", self.o_name[id]))
			self:_on_transport_launched(u, tg)
		end
		return true
	end

	-- Hook for the AI (a nation may answer an incoming transport).
	function C:_on_transport_launched(_u, _target_owner: number) end

	-- Owned coastal tile on `water_body` closest to `near` (-1 if none).
	function C:nearest_own_coast(id: number, water_body: number, near: number): number
		local owner = self.owner
		local map = self.map
		local cb = map.coast_body
		local coast_list = map.coast_list
		local dist2 = self.dist2
		local best = -1
		local bd = 1099511627776 -- 1 << 40
		for k = 0, map.coast_count - 1 do
			local c = readi32(coast_list, k * 4)
			if readi32(owner, c * 4) == id and readu16(cb, c * 2) == water_body then
				local d = dist2(c, near)
				if d < bd then
					bd = d
					best = c
				end
			end
		end
		return best
	end

	function C:_transport_arrive(u)
		local id = u.owner
		self:remove_unit(u, Defs.DEL_ARRIVED)
		if self.o_alive[id] == 0 then
			return
		end
		local t = u.target_tile
		if readi32(self.owner, t * 4) == id then
			-- A transport that lands on its own coast loses malusForRetreat (25 %).
			self.o_troops[id] += math.floor(u.troops * Rules.RETREAT_KEEP)
			self:msg(id, Defs.MSG_INFO, "Your transport returned its troops home")
			return
		end
		if not self:_landable(id, t) then
			t = self:_alt_landing(id, t, u.body)
			if t < 0 then
				self.o_troops[id] += math.floor(u.troops * 0.5)
				self:msg(id, Defs.MSG_BAD, "Your transport could not land")
				return
			end
		end
		local tg = readi32(self.owner, t * 4)
		if tg ~= 0 and not self:_landing_allowed(id, tg) then
			-- The coast changed hands while at sea and this attack isn't allowed (human protection).
			self.o_troops[id] += u.troops
			return
		end
		-- On landing, the tile is taken for free and every soldier
		-- on board starts an attack from it.
		local troops = u.troops
		self:conquer(t, id, nil)
		if tg ~= 0 then
			self:msg(id, Defs.MSG_GOOD, string.format("Your transport landed in %s", self.o_name[tg]))
			self:msg(tg, Defs.MSG_ALERT, string.format("%s landed troops on your coast!", self.o_name[id]))
		else
			self:msg(id, Defs.MSG_GOOD, "Your transport landed")
		end
		-- With nothing to push into, start_attack sends the troops home.
		self:start_attack(id, tg, troops, t)
	end

	-- Overridden by Sim: may `id`'s landing start an attack on `tg` right now?
	function C:_landing_allowed(_id: number, _tg: number): boolean
		return true
	end

	function C:_landable(id: number, t: number): boolean
		if readu8(self.land, t) == 0 then
			return false
		end
		local tg = readi32(self.owner, t * 4)
		return tg ~= id and not (tg ~= 0 and self:allied(id, tg))
	end

	function C:_alt_landing(id: number, t: number, water_body: number): number
		local W = self.W
		local H = self.H
		local cx = t % W
		local cy = t // W
		local coastal = self.map.coastal
		local cb = self.map.coast_body
		-- 3 tiles of the original 1024-wide Earth (~6 full-size tiles).
		local rmax = math.max(3, math.ceil(6.0 / self.R.K_LIN))
		for r = 1, rmax do
			for dy = -r, r do
				local y = cy + dy
				if y < 0 or y >= H then
					continue
				end
				for dx = -r, r do
					local x = cx + dx
					if x < 0 or x >= W then
						continue
					end
					local c = y * W + x
					if readu8(coastal, c) == 1 and readu16(cb, c * 2) == water_body and self:_landable(id, c) then
						return c
					end
				end
			end
		end
		return -1
	end

	-- =========================================================================================
	-- Trade
	-- =========================================================================================

	-- Ports: every 10 ticks each port launches a trade ship with probability
	-- 1 / tradeShipSpawnRate(rejections, trade ships at sea) (a pity timer raises the odds after
	-- each miss) to a port of another player it may trade with.
	function C:ports_tick()
		local tick = self.tick
		local slot = tick % 10
		local o_alive = self.o_alive
		local rng = self.rng
		for _, p in self.port_list do
			if p.next_tick ~= slot or o_alive[p.owner] == 0 or p.water < 0 then
				continue
			end
			-- One spawn roll per port level.
			local hit = false
			for _ = 1, p.level do
				if rng:randi() % Rules.trade_spawn_rate(p.rejections, self.n_trade) == 0 then
					hit = true
					break
				end
				p.rejections += 1
			end
			if not hit then
				continue
			end
			p.rejections = 0
			local dst = self:_pick_trade_port(p)
			if dst == nil then
				continue
			end
			local path = self:_trade_path(p, dst)
			if #path < 2 then
				if self.path_budget <= 0 then
					p.rejections += 1
				end
				continue
			end
			local u = Unit.new()
			u.kind = U_TRADE
			u.owner = p.owner
			u.path = path
			u.start_tick = tick
			u.tpt = self.R.TRADE_TPT_X100
			u.src_sid = p.sid
			u.dst_sid = dst.sid
			u.body = p.body
			u.end_tick = tick + ((#path - 1) * u.tpt + 99) // 100
			self:add_unit(u)
		end
	end

	function C:_pick_trade_port(p)
		if #p.partners == 0 or self.tick - p.partners_tick > 1200 then
			self:_refresh_partners(p)
		end
		local partners = p.partners
		local n = #partners
		local structs = self.structs
		for _ = 1, 3 do
			if n == 0 then
				return nil
			end
			local q = structs[partners[self.rng:randi() % n + 1]]
			if
				q == nil
				or q.kind ~= S_PORT
				or q.owner == p.owner
				or self.o_alive[q.owner] == 0
				or self:hostile(p.owner, q.owner)
			then
				continue
			end
			return q
		end
		p.partners_tick = -100000
		return nil
	end

	-- Keeps up to 8 trade partners per port, sampled with the partner weights of _trade_candidates.
	-- Valid partners are kept across refreshes so routes repeat and their paths stay cached.
	function C:_refresh_partners(p)
		p.partners_tick = self.tick
		local keep = {}
		local structs = self.structs
		for _, sid in p.partners do
			local q = structs[sid]
			if q ~= nil and q.kind == S_PORT and q.owner ~= p.owner and self.o_alive[q.owner] == 1 then
				table.insert(keep, sid)
			end
		end
		local partners = table.clone(keep)
		p.partners = partners
		local cands = {}
		local weights = {}
		self:_trade_candidates(p, cands, weights)
		for _ = 1, 8 - #keep do
			local q2 = self:_weighted_pick(cands, weights)
			if q2 == nil then
				break
			end
			if table.find(partners, q2.sid) == nil then
				table.insert(partners, q2.sid)
			end
		end
	end

	-- Trading partners: ports of other players on the same water that p may trade
	-- with, sorted by distance; weight 1, +1 for the nearest clamp(n / 3, 4, n) unless closer
	-- than tradeShipShortRangeDebuff, +1 for allies unless that close.
	function C:_trade_candidates(p, cands: { any }, weights: { number })
		local dists = {}
		local o_alive = self.o_alive
		local geo_manhattan = self.geo_manhattan
		local K_LIN = self.R.K_LIN
		for _, q in self.port_list do
			if q.body ~= p.body or q.owner == p.owner or q.water < 0 or o_alive[q.owner] == 0 then
				continue
			end
			if self:hostile(p.owner, q.owner) then
				continue
			end
			table.insert(dists, { geo_manhattan(p.tile, q.tile) * K_LIN, q })
		end
		-- Godot's sort_custom (unstable): equal distances end up in the Godot version's order.
		Defs.godot_sort(dists, function(a, b)
			return a[1] < b[1]
		end)
		local n = #dists
		local bonus_n = math.clamp(n // 3, math.min(4, n), n)
		for i = 1, n do
			local q = dists[i][2]
			local far = dists[i][1] >= Rules.TRADE_SHORT_RANGE_FULL
			-- Each entry counts once per level of the destination port.
			local lv = q.level
			local w = lv
			if far and i - 1 < bonus_n then
				w += lv
			end
			if far and self:allied(p.owner, q.owner) then
				w += lv
			end
			table.insert(cands, q)
			table.insert(weights, w)
		end
	end

	function C:_weighted_pick(cands: { any }, weights: { number })
		local n = #cands
		if n == 0 then
			return nil
		end
		local total = 0.0
		for _, w in weights do
			total += w
		end
		local r = self.rng:randf() * total
		for i = 1, n do
			r -= weights[i]
			if r <= 0.0 then
				return cands[i]
			end
		end
		return cands[n]
	end

	function C:_trade_path(a, b): { number }
		local cache = self.trade_cache
		local key = a.sid * KEY_SHIFT + b.sid
		local cached = cache[key]
		if cached ~= nil then
			return cached
		end
		local rev_src = cache[b.sid * KEY_SHIFT + a.sid]
		if rev_src ~= nil then
			local n = #rev_src
			local rev = table.create(n)
			for i = 1, n do
				rev[i] = rev_src[n + 1 - i]
			end
			cache[key] = rev
			return rev
		end
		if self.path_budget <= 0 then
			return {}
		end
		self.path_budget -= 1
		local path = self.nav:find_path(a.water, b.water)
		cache[key] = path
		return path
	end

	-- Arrival: tradeShipGold(tiles sailed) to both ports' owners, or - for
	-- a captured ship - to its captor alone (to the original owner when it was retaken).
	function C:_trade_arrive(u)
		self:remove_unit(u, Defs.DEL_ARRIVED)
		local g = self.R.trade_gold(u.traveled + #u.path)
		local dst = self.structs[u.dst_sid]
		-- Each earner's map shows the gold over a port (Ev.BONUS, a person
		-- only). The sender's is the port the ship left (its home port; the one it reached when that port
		-- is gone or lost), the receiver's and a captor's the port it reached.
		if u.orig_owner ~= 0 then
			if dst ~= nil and dst.owner == u.owner then
				self:add_bonus_gold(u.owner, g, dst.tile)
			end
			return
		end
		local src = self.structs[u.src_sid]
		self:add_bonus_gold(
			u.owner,
			g,
			if src ~= nil and src.owner == u.owner then src.tile elseif dst ~= nil then dst.tile else nil
		)
		if dst ~= nil and dst.owner ~= u.owner and not self:hostile(dst.owner, u.owner) then
			self:add_bonus_gold(dst.owner, g, dst.tile)
		end
	end

	-- =========================================================================================
	-- Per-tick unit processing
	-- =========================================================================================

	-- Owners' units are removed on elimination, so only due units need work here.
	function C:units_tick()
		local list = self.unit_list
		local n = #list
		local tick = self.tick
		for i = 1, n do
			local u = list[i]
			if u.dead or tick < u.next_tick then
				continue
			end
			local k = u.kind
			if k == U_TRANSPORT then
				self:_transport_arrive(u)
			elseif k == U_TRADE then
				self:_trade_arrive(u)
			elseif k == U_TRUCK then
				self:_truck_tick(u)
			end
			if i % 32 == 0 then
				Coop.check() -- (a local match's step is spread over frames: Session._local_process)
			end
		end
		self:compact_units()
	end

	function C:remove_units_of(id: number)
		for _, u in self.unit_list do
			if not u.dead and u.owner == id then
				self:remove_unit(u, Defs.DEL_DESTROYED)
			end
		end
	end
end

return SimNaval
