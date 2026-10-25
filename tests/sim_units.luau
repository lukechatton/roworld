-- sim-core: unit tests for the tricky pieces of SimState / SimAttacks / Sim
-- (range metric, disk_tiles, border lists, frontier queue, attack cost formulas, scans, 0/1-based
-- conversions, intents parsing) on an imported map (pangaea, flat, no wrap).
-- Run: .bin/lune run tests/sim_units.luau
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local Rules = require("../src/shared/Core/Rules")
local Rng = require("../src/shared/Core/Rng")
local WorldMap = require("../src/shared/Core/WorldMap")
local SimState = require("../src/shared/Core/SimState")
local SimAttacks = require("../src/shared/Core/SimAttacks")
local Sim = require("../src/shared/Core/Sim")
local GameState = require("../src/shared/Core/GameState")

local fails = 0
local function expect(cond: boolean, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local readi32 = buffer.readi32
local readu8 = buffer.readu8
local map = WorldMap.get("pangaea")
local W, H, N = map.W, map.H, map.N
--- Land tile number k of the map (0-based) — the map's land list.
local function land_tiles(): { number }
	local out = table.create(map.land_count)
	for k = 0, map.land_count - 1 do
		out[k + 1] = map:land_tile(k)
	end
	return out
end
local LAND = land_tiles()

-- A bare state (SimState + SimAttacks only) on the real map, no owners placed.
local Bare = {}
Bare.__index = Bare
SimState.install(Bare)
SimAttacks.install(Bare)
local function bare(seed: number): any
	local s = setmetatable({}, Bare)
	s.rng = Rng.new(seed)
	s:_init_state(map)
	s:_init_attacks()
	return s
end

-- =============================================================================================
-- Range metric
-- =============================================================================================
do
	local rng = Rng.new(5)
	local bad = 0
	local s = bare(1)
	for _ = 1, 4000 do
		local a = rng:randi_range(0, N - 1)
		local b = rng:randi_range(0, N - 1)
		local ax, ay = a % W, a // W
		local bx, by = b % W, b // W
		local want = (ax - bx) ^ 2 + (ay - by) ^ 2
		local man = math.abs(ax - bx) + math.abs(ay - by)
		if s.range_d2(a, b) ~= want or s.dist2(a, b) ~= want or s.geo_manhattan(a, b) ~= man then
			bad += 1
		end
	end
	expect(bad == 0, "range_d2 / dist2 = dx^2 + dy^2 and geo_manhattan = |dx| + |dy| (no wrap) on 4000 pairs")
	local rng2 = Rng.new(7)
	local dbad = 0
	for i = 1, 40 do
		local c = rng2:randi_range(0, N - 1)
		if i <= 4 then
			c = ({ 1 * W + 3, (H - 2) * W + W - 4, 256 * W + 0, 256 * W + W - 1 })[i]
		end
		local r = rng2:randf_range(0.5, 60)
		local got = {}
		local n = 0
		local dup = false
		for _, t in s:disk_tiles(c, r, false) do
			if got[t] then
				dup = true
			end
			got[t] = true
			n += 1
		end
		local want = 0
		for y = math.max(c // W - math.ceil(r), 0), math.min(c // W + math.ceil(r), H - 1) do
			for x = 0, W - 1 do
				local t = y * W + x
				if s.range_d2(c, t) <= r * r then
					want += 1
					if not got[t] then
						dbad += 1
					end
				end
			end
		end
		if want ~= n or dup then
			dbad += 1
		end
		-- only_land keeps exactly the contestable tiles
		local land_n = 0
		for _, t in s:disk_tiles(c, r) do
			if readu8(s.land, t) ~= 1 then
				dbad += 1
			end
			land_n += 1
		end
		local want_land = 0
		for t in got do
			if readu8(s.land, t) == 1 then
				want_land += 1
			end
		end
		if land_n ~= want_land then
			dbad += 1
		end
	end
	expect(dbad == 0, "disk_tiles exact (40 disks incl. the map edges), no duplicates, only_land filter")
	expect(s.geo_span(256 * W, 10) == 10 and s.geo_span(5 * W, 9.5) == 10, "geo_span = ceil(r)")
	expect(
		SimState.a_an("Atom Bomb") == "an Atom Bomb"
			and SimState.a_an("City") == "a City"
			and SimState.cap_first("abc") == "Abc",
		"a_an / cap_first"
	)
end

-- =============================================================================================
-- Border lists under random ownership changes
-- =============================================================================================
local function check_borders(s: any, label: string): boolean
	local ok = true
	local owner, land, in_border = s.owner, s.land, s.in_border
	local want_count = {}
	for t = 0, N - 1 do
		local o = readi32(owner, t * 4)
		local is_b = false
		if o ~= 0 then
			is_b = s:_is_border(t, o)
			if is_b then
				want_count[o] = (want_count[o] or 0) + 1
			end
		end
		if (readu8(in_border, t) == 1) ~= is_b then
			ok = false
		end
	end
	for o = 1, 20 do
		local n = 0
		local prev = -1
		local t = s.bhead[o]
		while t ~= -1 do
			if readi32(s.bprev, t * 4) ~= prev or readi32(owner, t * 4) ~= o or readu8(in_border, t) ~= 1 then
				ok = false
				break
			end
			n += 1
			prev = t
			t = readi32(s.bnext, t * 4)
			if n > N then
				ok = false
				break
			end
		end
		if n ~= (want_count[o] or 0) or s.bcount[o] ~= n then
			ok = false
		end
	end
	expect(ok, "border lists exact: in_border, doubly linked, bcount (" .. label .. ")")
	return ok
end

do
	local s = bare(3)
	for i = 1, 20 do
		s:add_owner("O" .. i, 0xffffffff, Defs.KIND_NATION)
	end
	local rng = Rng.new(11)
	-- blobs around random centres
	local lt = LAND
	local centres = {}
	for o = 1, 20 do
		centres[o] = lt[rng:randi() % #lt + 1]
		for _, t in s:disk_tiles(centres[o], rng:randf_range(3, 25)) do
			s:set_owner(t, o)
		end
	end
	check_borders(s, "after blobs")
	for _ = 1, 20000 do
		local o = rng:randi_range(0, 20)
		local c = centres[rng:randi_range(1, 20)]
		local t = c + rng:randi_range(-30, 30) + rng:randi_range(-30, 30) * W
		if t >= 0 and t < N and readu8(s.land, t) == 1 then
			s:set_owner(t, o)
		end
	end
	check_borders(s, "after 20000 random set_owner")
	-- tile counts, centroid sums, coast counts
	local cnt, coast = {}, {}
	for t = 0, N - 1 do
		local o = readi32(s.owner, t * 4)
		if o ~= 0 then
			cnt[o] = (cnt[o] or 0) + 1
			if readu8(map.coastal, t) == 1 then
				coast[o] = (coast[o] or 0) + 1
			end
		end
	end
	local ok = true
	for o = 1, 20 do
		if s.o_tiles[o] ~= (cnt[o] or 0) or s.o_coast[o] ~= (coast[o] or 0) then
			ok = false
		end
	end
	expect(ok, "o_tiles / o_coast follow set_owner")
	-- owned_tiles (1-based array) == every tile of o 4-connected to one of o's border tiles
	local ot_ok = true
	for o = 1, 20 do
		local got = {}
		local n = 0
		for _, t in s:owned_tiles(o) do
			if got[t] or readi32(s.owner, t * 4) ~= o then
				ot_ok = false
			end
			got[t] = true
			n += 1
		end
		local seen = {}
		local q = {}
		for t = 0, N - 1 do
			if readi32(s.owner, t * 4) == o and readu8(s.in_border, t) == 1 then
				seen[t] = true
				table.insert(q, t)
			end
		end
		local i = 1
		while i <= #q do
			local t = q[i]
			i += 1
			local x = t % W
			for _, nb in
				{
					if x > 0 then t - 1 else -1,
					if x < W - 1 then t + 1 else -1,
					if t >= W then t - W else -1,
					if t < N - W then t + W else -1,
				}
			do
				if nb >= 0 and not seen[nb] and readi32(s.owner, nb * 4) == o then
					seen[nb] = true
					table.insert(q, nb)
				end
			end
		end
		if #q ~= n then
			ot_ok = false
		end
	end
	expect(ot_ok, "owned_tiles reaches every tile connected to the border list")
	-- scan_border (full walk) == brute force neighbour census
	local sc_ok = true
	for o = 1, 20 do
		if s.bcount[o] == 0 then
			continue
		end
		s:scan_border(o, s.bcount[o])
		local want = {}
		local neutral = 0
		local t = s.bhead[o]
		while t ~= -1 do
			local x = t % W
			for k = 1, 4 do
				local n
				if k == 1 then
					n = if x > 0 then t - 1 else -1
				elseif k == 2 then
					n = if x < W - 1 then t + 1 else -1
				elseif k == 3 then
					n = if t >= W then t - W else -1
				else
					n = if t < N - W then t + W else -1
				end
				if n >= 0 and readu8(s.land, n) == 1 then
					local on = readi32(s.owner, n * 4)
					if on == 0 then
						neutral += 1
					elseif on ~= o then
						want[on] = (want[on] or 0) + 1
					end
				end
			end
			t = readi32(s.bnext, t * 4)
		end
		if s.sc_neutral ~= neutral then
			sc_ok = false
		end
		local nlist = 0
		for _, p in s.sc_list do
			nlist += 1
			if s.sc_count[p] ~= want[p] or readi32(s.owner, s.sc_tile[p] * 4) ~= p then
				sc_ok = false
			end
		end
		local nwant = 0
		for _ in want do
			nwant += 1
		end
		if nlist ~= nwant then
			sc_ok = false
		end
		if s.sc_neutral > 0 and readi32(s.owner, s.sc_neutral_tile * 4) ~= 0 then
			sc_ok = false
		end
	end
	expect(sc_ok, "scan_border census (sc_list 1-based, sc_count / sc_tile by id, sc_neutral)")
	-- borders() vs census, top_owners order
	local top = s:top_owners()
	local top_ok = #top == 5
	for i = 2, #top do
		if s.o_tiles[top[i - 1]] < s.o_tiles[top[i]] then
			top_ok = false
		end
	end
	expect(top_ok, "top_owners returns 5 ids by land, largest first")
	-- d_tiles packing
	local last = s.d_tiles[#s.d_tiles]
	expect(readi32(s.owner, (last // 1024) * 4) ~= nil and last % 1024 <= 20, "d_tiles packs tile*1024+owner")
end

-- =============================================================================================
-- Frontier queue and attack formulas
-- =============================================================================================
do
	local s = bare(9)
	local a_id = s:add_owner("A", 0xffffffff, Defs.KIND_NATION)
	local b_id = s:add_owner("B", 0xffffffff, Defs.KIND_NATION)
	s.tick = 100
	-- A: a plains blob; find a large all-plains area away from the map edges
	local centre = -1
	for _, t in LAND do
		if t // W > 40 and t // W < H - 40 and t % W > 40 and t % W < W - 40 then
			local good = true
			for _, c in s:disk_tiles(t, 12, false) do
				if readu8(map.terrain, c) ~= Defs.T_PLAINS then
					good = false
					break
				end
			end
			if good then
				centre = t
				break
			end
		end
	end
	expect(centre >= 0, "found an all-plains test area")
	for _, t in s:disk_tiles(centre, 3) do
		s:set_owner(t, a_id)
	end
	s.o_troops[a_id] = 0
	local a = s:start_attack(a_id, 0, 100000.0, -1)
	expect(a ~= nil and a.front > 0, "expansion started with a frontier")
	-- every queued tile touches A and is unowned; the border set = the distinct queued tiles
	local q_ok = true
	local queued = 0
	local distinct = {}
	local nd = 0
	local function scan(b: { number })
		for _, t in b do
			queued += 1
			if not s:touches(t, a_id) or readi32(s.owner, t * 4) ~= 0 then
				q_ok = false
			end
			if not distinct[t] then
				distinct[t] = true
				nd += 1
				if not SimAttacks.in_border(s, a, t) then
					q_ok = false
				end
			end
		end
	end
	for _, b in a.ring do
		scan(b)
	end
	for _, b in a.over or {} do
		scan(b)
	end
	expect(
		q_ok and queued == SimAttacks.qsize(a) and a.front == nd,
		"frontier holds unowned tiles touching the attacker"
	)
	-- pop order: lowest key (4 x the tile's priority) first, the border shrinks as tiles leave
	local fake = SimAttacks.new_attack()
	-- 1000 and 5000 lie outside the ring window (overflow); -3 lowers the window's start
	local keys = { 40, 7, 1000, 8, 41, -3, 5000, 300 }
	for i, k in keys do
		SimAttacks._enqueue(fake, 100 + i, k)
	end
	local order = {}
	for _ = 1, #keys do
		table.insert(order, SimAttacks._dequeue(fake))
	end
	local want_order = { 106, 102, 104, 101, 105, 108, 103, 107 }
	local pop_ok = SimAttacks._dequeue(fake) == -1 and SimAttacks.qsize(fake) == 0
	for i, v in want_order do
		pop_ok = pop_ok and order[i] == v
	end
	expect(pop_ok, "the queue pops the lowest priority key first (ring + overflow), -1 when empty")
	-- a tile in two attacks' borders at once is counted by both
	do
		local shared = -1
		for _, bk in a.ring do
			if #bk > 0 then
				shared = bk[1]
				break
			end
		end
		local other = SimAttacks.new_attack()
		other.aid = 999
		other.attacker = a_id
		s.attack_by_id[999] = other
		local f0 = other.front
		SimAttacks._push(s, other, shared)
		SimAttacks._push(s, other, shared)
		expect(
			other.front == f0 + 1 and SimAttacks.in_border(s, other, shared) and SimAttacks.in_border(s, a, shared),
			"border sets of two attacks may share a tile"
		)
		SimAttacks._pop(s, other)
		SimAttacks._pop(s, other)
		expect(other.front == 0 and SimAttacks.in_border(s, a, shared), "popping from one keeps the other's border")
		s.attack_by_id[999] = nil
	end
	-- priority factor 4 x (1 - 0.5 n + mag / 2): plains n = 0 → 6, n = 1 → 4, mountain n = 1 → 6
	expect(
		SimAttacks.PRIORITY_F4[Defs.T_PLAINS * 5] == 6
			and SimAttacks.PRIORITY_F4[Defs.T_PLAINS * 5 + 1] == 4
			and SimAttacks.PRIORITY_F4[Defs.T_PLAINS * 5 + 4] == -2
			and SimAttacks.PRIORITY_F4[Defs.T_HIGHLAND * 5 + 1] == 5
			and SimAttacks.PRIORITY_F4[Defs.T_MOUNTAIN * 5 + 1] == 6,
		"addNeighbors priority factors"
	)
	-- troop cost on plains: 16 * K_AREA per tile for a nation (mag 80 / 5)
	local before = a.troops
	local tiles_before = s.o_tiles[a_id]
	s.tick += 1 -- a new attack starts conquering the tick after the order
	for _ = 1, 30 do
		s.tick += 1
		s:attacks_tick()
	end
	local gained = s.o_tiles[a_id] - tiles_before
	local spent = before - a.troops
	local per_tile = spent / math.max(gained, 1)
	local want = 80 / 5 * Rules.K_AREA
	-- partial progress (chew) on the head tile is included in `spent`
	expect(
		gained > 20 and math.abs(per_tile - want) / want < 0.08,
		string.format("neutral plains loss %.1f troops/tile (want %.1f), %d tiles in 3 s", per_tile, want, gained)
	)
	-- speed: ~ full-size tiles per tick = 2 * border / clamp(2000*tc/troops,5,100) → our tiles/s
	expect(gained / 3 > 5, string.format("expansion speed %.1f tiles/s with a %d-tile front", gained / 3, a.front))

	-- player attack: first tile's attacker loss per full-size tile matches attackLogic
	local s3 = bare(12)
	local p1 = s3:add_owner("P1", 0xffffffff, Defs.KIND_NATION)
	local p2 = s3:add_owner("P2", 0xffffffff, Defs.KIND_NATION)
	s3.tick = 50
	local x0 = centre % W
	local y0 = centre // W
	for dy = -6, 6 do
		for dx = -12, 12 do
			local t = (y0 + dy) * W + (x0 + dx) % W
			if readu8(s3.land, t) == 1 then
				s3:set_owner(t, if dx < 0 then p1 else p2)
			end
		end
	end
	s3.o_troops[p1] = 0
	s3.o_troops[p2] = 50000.0
	local tiles2 = s3.o_tiles[p2]
	local att = s3:start_attack(p1, p2, 40000.0, -1)
	expect(att ~= nil, "player attack started")
	local t0 = att.troops
	local def0 = s3.o_troops[p2]
	s3.tick += 1
	-- replicate attackLogic for the first full-size tile (plains, no posts, no traitor, no fallout)
	local att_of = s3.o_tiles[p1] * Rules.K_AREA
	local def_of = math.max(tiles2 * Rules.K_AREA, 1)
	local ldb = Rules.large_territory_bonus(def_of, Rules.LARGE_DEFENDER_DEPTH)
	local bonus_l = Rules.ATTACKER_LOSS_BASE * Rules.large_territory_bonus(att_of, Rules.LARGE_ATTACKER_DEPTH) * ldb
	local dloss = def0 / math.max(tiles2 * Rules.K_AREA, 1)
	local dfloor = math.floor(dloss) -- removeTroops floors the defender's per-tile loss
	local ratio = def0 / t0
	local loss = 80 * math.clamp(ratio, 0.6, 2.0) * (bonus_l + Rules.ATTACKER_LOSS_PER_DENSITY * dloss)
	s3:attacks_tick()
	local lost = t0 - att.troops
	local dlost = def0 - s3.o_troops[p2]
	-- the defender loses floor(dloss) per full-size tile processed; the attacker loss per full-size tile is `loss`
	local src_tiles = dlost / dfloor
	-- (ratio and density move a little between the full-size tiles of one tick, hence 1 %)
	expect(
		src_tiles > 0 and math.abs(lost / src_tiles - loss) / loss < 0.01,
		string.format("attacker loss per full-size tile %.3f ~ attackLogic %.3f", lost / math.max(src_tiles, 1e-9), loss)
	)
	local ev_ok = false
	for _, e in s3.d_ev do
		if e[1] == Ev.ATTACK and e[2] == att.aid and e[3] == p1 and e[4] == p2 then
			ev_ok = true
		end
	end
	expect(ev_ok, "ATTACK event {Ev.ATTACK, aid, attacker, target, troops, anchor}")
	-- opposing attack cancels troops 1:1, merge adds
	s3.o_troops[p2] = 100000.0
	local before_att = att.troops
	local counter = s3:start_attack(p2, p1, 1000.0, -1)
	expect(
		counter ~= nil
				and counter.counter
				and math.abs(att.troops - (before_att - 1000.0)) < 1e-6
				and counter.troops == 0
			or att.troops == before_att - 1000,
		"opposing attack cancels 1:1"
	)
	local merged = s3:start_attack(p1, p2, 500.0, -1)
	expect(merged == att and att.pend == 500.0, "an order on the same target waits to be absorbed")
	s3.tick += 1
	local before_tick = att.troops
	s3:attacks_tick()
	expect(att.pend == 0 and not att.dead, "attacks on the same target merge at the end of the tick")
	local _ = before_tick
	-- retreat: frozen after the next tick, home 20 ticks after the order, a
	-- player attack loses 25 % (floored: troops are whole numbers)
	local home = s3.o_troops[p1]
	local order_tick = s3.tick
	expect(s3:retreat(p1, att.aid) and not att.dead, "a retreat order keeps the attack for cancelDelay")
	s3.tick = order_tick + 2
	s3:attacks_tick()
	local left = att.troops
	local tiles_frozen = s3.o_tiles[p1]
	for k = 3, 20 do
		s3.tick = order_tick + k
		s3:attacks_tick()
	end
	expect(
		not att.dead and att.troops == left and s3.o_tiles[p1] == tiles_frozen and s3.o_troops[p1] == home,
		"a retreating attack is frozen"
	)
	s3.tick = order_tick + 21
	s3:attacks_tick()
	expect(
		s3.o_troops[p1] == home + math.floor(left * 0.75) and att.dead and s3:attack_between(p1, p2) == nil,
		"retreat returns 75 % after 20 ticks and clears pair_attack"
	)
end

-- =============================================================================================
-- Sim-level: intents parsing, snapshot rows, stats rows
-- =============================================================================================
do
	local sim = Sim.new(map, { seed = 4, difficulty = 1, tribes = 10, max_humans = 1 })
	local h = sim:add_human("k", "")
	expect(sim.o_name[h] == "Commander", "empty display name → Commander")
	expect(sim:add_human("k", "x") == h, "same key → same id")
	-- garbage intents never crash
	local garbage = {
		{ type = "attack", tile = "x", ratio = {} },
		{ type = "spawn", tile = 0 / 0 },
		{ type = "spawn", tile = math.huge },
		{ type = "build", kind = 5, tile = 1.5 },
		{ type = "nuke", kind = "mirv", tile = -5 },
		{ type = "ally_reply", target = 1, accept = "yes" },
		{ type = {} },
		{},
	}
	for _, g in garbage do
		sim:submit(h, g :: any)
	end
	sim:submit(9999, { type = "spawn", tile = 5 })
	sim:submit(-1 :: any, { type = "spawn", tile = 5 })
	local ok = pcall(function()
		sim:step()
	end)
	expect(ok, "garbage intents are ignored without errors")
	expect(sim.phase == Defs.PHASE_SPAWN and sim:spawn_ticks_left() == -1, "solo waits for the pick (-1)")
	-- spawn pick → countdown → SPAWNED next tick → PLAYING
	local start = -1
	for _, t in LAND do
		if readi32(sim.owner, t * 4) == 0 and sim:_area_free(t, 8) then
			start = t
			break
		end
	end
	expect(sim:human_start(h, start), "human_start accepted")
	local d = sim:step()
	local spawned = false
	for _, e in d.ev do
		if e[1] == Ev.SPAWNED and e[2] == h and e[3] == start then
			spawned = true
		end
	end
	expect(spawned and readi32(sim.owner, start * 4) == h, "start disk claimed on the next tick (SPAWNED)")
	expect(d.stats ~= nil and #d.stats % 6 == 0, "stats forced after a spawn, 6 ints per row")
	for _ = 1, Rules.SOLO_COUNTDOWN_TICKS do
		sim:step()
	end
	expect(sim.phase == Defs.PHASE_PLAYING and sim.playing_since > 0, "countdown → PLAYING")
	-- the countdown can be set (the tutorial's match starts a second after the capital is placed)
	do
		local quick = Sim.new(MAP, { seed = 5, tribes = 4, max_humans = 1, solo_countdown_ticks = 10 })
		local qh = quick:add_human("q", "Quick")
		local qs = -1
		for _, t in LAND do
			if readi32(quick.owner, t * 4) == 0 and quick:_area_free(t, 8) then
				qs = t
				break
			end
		end
		expect(quick:human_start(qh, qs) and quick:spawn_ticks_left() == 10, "solo_countdown_ticks sets the countdown")
		for _ = 1, 11 do
			quick:step()
		end
		expect(quick.phase == Defs.PHASE_PLAYING, "and the match is on after it")
	end
	local snap = sim:snapshot()
	local row = snap.owners[h]
	expect(
		row[1] == h
			and row[2] == sim.o_name[h]
			and row[3] == sim.o_color[h]
			and row[4] == Defs.KIND_HUMAN
			and row[6] == true
			and row[13] == start,
		"snapshot owner row layout"
	)
	expect(
		typeof(snap.owner) == "buffer" and buffer.len(snap.owner) == N * 4 and typeof(snap.flags) == "buffer",
		"snapshot grids are buffers"
	)
	local gs = GameState.new(map)
	gs:load_snapshot(snap)
	expect(
		gs:tile_owner(start) == h and gs.owners[h].spawned and gs.playing_since == sim.playing_since,
		"GameState loads the Sim snapshot"
	)
	-- attack intent from the human into neutral land is an auto expansion
	sim:scan_border(h, 1000)
	local home = sim.o_troops[h]
	sim:submit(h, { type = "attack", tile = sim.sc_neutral_tile, ratio = 0.5 })
	sim:step()
	local ex = sim:attack_between(h, 0)
	-- growth runs on the troops held before the order; the attack takes floor(troops * ratio)
	local grown = home + Rules.troop_growth_applied(Defs.KIND_HUMAN, home, sim.o_cap[h], sim.difficulty)
	expect(
		ex ~= nil and ex.troops == math.floor(grown * 0.5) and sim.o_troops[h] == grown - math.floor(grown * 0.5),
		"human expansion takes floor(troops * ratio) after this tick's growth"
	)
	-- messages: only for humans
	local before = #sim.d_ev
	sim:msg(1, Defs.MSG_INFO, "to a nation")
	sim:msg(h, Defs.MSG_INFO, "to the human")
	expect(#sim.d_ev == before + 1 and sim.d_ev[#sim.d_ev][4] == "to the human", "MSG only emitted for humans")
	-- not-bordering refusal message text
	local far = -1
	for _, t in LAND do
		if
			readi32(sim.owner, t * 4) ~= 0
			and readi32(sim.owner, t * 4) ~= h
			and not sim:borders(h, readi32(sim.owner, t * 4))
		then
			far = t
			break
		end
	end
	sim.d_ev = {}
	local r = sim:intent_attack(h, far, 0.1)
	local txt = sim.d_ev[#sim.d_ev] and sim.d_ev[#sim.d_ev][4] or ""
	expect(
		not r and txt == "You don't border " .. sim.o_name[readi32(sim.owner, far * 4)] .. " — send a boat",
		"refusal text: " .. txt
	)
end

print(fails == 0 and "sim_units ok" or ("sim_units FAILED " .. fails))
if fails > 0 then
	error("failures")
end
