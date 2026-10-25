-- sim-systems: SimStructures tests (placement, upgrades, costs, construction, capture, cover,
-- roads, trucks, snapshot rows). Run: .bin/lune run tests/simsys_structures.luau
local F = require("./simsys_fixture")
local Defs, Ev, Rules = F.Defs, F.Ev, F.Rules
local expect, near = F.expect, F.near

local STRUCT_KINDS = 16
local range_d2 = F.map.range_d2
local md = Rules.STRUCT_MIN_DIST
local md2 = md * md

-- =============================================================================================
print("placement / costs / construction / upgrade")
do
	local sim = F.new_sim(1)
	local A = F.owner(sim, "Alpha", Defs.KIND_HUMAN, 10000000)
	local c = F.claim(sim, A, 700, 120, 15)
	F.clear(sim)
	local p0 = Rules.place_site(sim.map, sim.owner, sim.map.coastal, A, Defs.S_CITY, c, sim:near_rows(c), sim.tick)
	expect(
		p0.tile == c and p0.upgrade_sid == 0 and p0.reason == "",
		"place_site on empty own land keeps the clicked tile"
	)
	expect(sim:try_build(A, "city", c), "try_build city")
	local s1 = sim.structs[1]
	expect(
		s1 ~= nil and s1.tile == c and s1.kind == Defs.S_CITY and s1.owner == A and s1.level == 1,
		"city 1 at the click"
	)
	expect(near(sim.o_gold[A], 10000000 - 125000), "first city costs 125K")
	expect(
		s1.active_tick == sim.tick + Rules.BUILD_TICKS[Defs.S_CITY] and not s1.active,
		"construction: active_tick = tick + 20, inactive"
	)
	expect(buffer.readi32(sim.struct_at, c * 4) == 1, "struct_at marks the tile")
	local adds = F.events(sim, Ev.STRUCT_ADD)
	local lvls = F.events(sim, Ev.STRUCT_LEVEL)
	expect(
		#adds == 1 and adds[1][2] == 1 and adds[1][3] == Defs.S_CITY and adds[1][4] == A and adds[1][5] == c,
		"STRUCT_ADD sid, kind, owner, tile"
	)
	expect(
		#lvls == 1 and lvls[1][2] == 1 and lvls[1][3] == 1 and lvls[1][4] == s1.active_tick,
		"STRUCT_LEVEL sid, 1, active_tick right after STRUCT_ADD"
	)
	local ia, il
	for i, e in sim.d_ev do
		if e[1] == Ev.STRUCT_ADD then
			ia = i
		elseif e[1] == Ev.STRUCT_LEVEL then
			il = i
		end
	end
	expect(ia ~= nil and il == ia + 1, "STRUCT_LEVEL follows STRUCT_ADD")
	expect(
		sim:struct_count(A, Defs.S_CITY) == 1
			and sim:struct_levels(A, Defs.S_CITY) == 1
			and sim.o_built[A * STRUCT_KINDS + Defs.S_CITY] == 1,
		"counts: scount / slevel / built"
	)
	expect(sim.o_alevel[A * STRUCT_KINDS + Defs.S_CITY] == 0, "alevel 0 while under construction")
	expect(#sim.building == 1, "queued in building")

	-- A click on the unfinished city's own tile finds no room (every tile within PLACE_SEARCH_R
	-- is closer than STRUCT_MIN_DIST to it) and does not upgrade it.
	F.clear(sim)
	expect(
		not sim:try_build(A, "city", c) and F.has_msg(sim, "No room for a City there", A),
		"click on an unfinished city: no room"
	)
	-- A click 6 rows away snaps to the nearest free tile.
	local g0 = sim.o_gold[A]
	local click2 = F.tile(700, 126)
	expect(sim:try_build(A, "city", click2), "second city (first unfinished)")
	local s2 = sim.structs[2]
	expect(s2 ~= nil and s2.tile ~= click2, "second city snapped away from the click")
	expect(
		range_d2(c, s2.tile) >= md2 and range_d2(click2, s2.tile) < Rules.PLACE_SEARCH_R ^ 2,
		"second city >= STRUCT_MIN_DIST from the first, within PLACE_SEARCH_R of the click"
	)
	-- nearest possible: no own tile closer to the click that is also valid
	local better = false
	for _, t in sim:disk_tiles(click2, Rules.PLACE_SEARCH_R, true) do
		if
			buffer.readi32(sim.owner, t * 4) == A
			and range_d2(click2, t) < Rules.PLACE_SEARCH_R ^ 2
			and range_d2(c, t) >= md2
			and range_d2(click2, t) < range_d2(click2, s2.tile) - 1e-9
		then
			better = true
		end
	end
	expect(not better, "second city is the nearest valid tile to the click")
	expect(near(g0 - sim.o_gold[A], 250000), "second city costs 250K (count 1)")

	-- Finish construction; a click near city 1 now upgrades it.
	F.advance(sim, 20)
	sim:construction_tick()
	expect(s1.active and s2.active and #sim.building == 0, "both active after 20 ticks")
	expect(sim.o_alevel[A * STRUCT_KINDS + Defs.S_CITY] == 2, "alevel 2")
	F.clear(sim)
	g0 = sim.o_gold[A]
	local click = c + 1
	expect(sim:try_build(A, "city", click), "upgrade click")
	expect(s1.level == 2 and sim.structs[3] == nil, "city 1 upgraded to level 2, no new structure")
	expect(near(g0 - sim.o_gold[A], 500000), "upgrade costs like a third city (500K)")
	lvls = F.events(sim, Ev.STRUCT_LEVEL)
	expect(
		#lvls == 1 and lvls[1][2] == 1 and lvls[1][3] == 2 and lvls[1][4] == s1.active_tick,
		"STRUCT_LEVEL on upgrade"
	)
	expect(
		sim:struct_levels(A, Defs.S_CITY) == 3
			and sim.o_built[A * STRUCT_KINDS] == 3
			and sim.o_alevel[A * STRUCT_KINDS] == 3,
		"level sums after upgrade"
	)
	expect(
		sim:cost_count(A, Defs.S_CITY) == 3 and Rules.build_cost_kind(Defs.S_CITY, 3) == 1000000,
		"4th city level would cost 1M"
	)
	-- ports and factories share one count
	sim.o_slevel[A * STRUCT_KINDS + Defs.S_PORT] = 2
	sim.o_built[A * STRUCT_KINDS + Defs.S_PORT] = 1
	sim.o_slevel[A * STRUCT_KINDS + Defs.S_FACTORY] = 1
	sim.o_built[A * STRUCT_KINDS + Defs.S_FACTORY] = 3
	expect(
		sim:cost_count(A, Defs.S_PORT) == 2 and sim:cost_count(A, Defs.S_FACTORY) == 2,
		"port/factory cost count = min(port) + min(factory)"
	)
	sim.o_slevel[A * STRUCT_KINDS + Defs.S_PORT] = 0
	sim.o_built[A * STRUCT_KINDS + Defs.S_PORT] = 0
	sim.o_slevel[A * STRUCT_KINDS + Defs.S_FACTORY] = 0
	sim.o_built[A * STRUCT_KINDS + Defs.S_FACTORY] = 0

	-- SAM / silo upgrades add a reloading missile slot; SAM up_tick
	local sam_t = F.tile(700, 132)
	expect(sim:try_build(A, "sam", sam_t), "SAM build")
	local sam = sim.structs[3]
	expect(sam.kind == Defs.S_SAM and sam.active_tick == sim.tick + 300, "SAM construction 300 ticks")
	F.advance(sim, 300)
	sim:construction_tick()
	expect(sam.active, "SAM active after 30 s")
	expect(sim:try_build(A, "sam", sam.tile), "SAM upgrade")
	expect(
		sam.level == 2 and #sam.shots == 1 and sam.shots[1] == sim.tick and sam.up_tick == sim.tick,
		"SAM upgrade: level 2, new missile reloading, up_tick"
	)
	expect(sim:ready_missiles(sam, Rules.SAM_COOLDOWN_TICKS) == 1, "one of two missiles ready right after the upgrade")
	-- the client learns the reload timers (the readiness bar under SAMs / silos) from Ev.STRUCT_SHOTS
	-- and from the snapshot's structure rows
	local shots_ev = F.events(sim, Ev.STRUCT_SHOTS)
	local last = shots_ev[#shots_ev]
	expect(last ~= nil and last[2] == sam.sid and #last[3] == 1 and last[3][1] == sim.tick, "Ev.STRUCT_SHOTS after the upgrade")
	local row = nil
	for _, r in sim:struct_rows() do
		if r[1] == sam.sid then
			row = r
		end
	end
	expect(row ~= nil and type(row[7]) == "table" and row[7][1] == sim.tick, "snapshot row carries the reloading shots")
	local GameState = require("../src/shared/Core/GameState")
	local gs = GameState.new(sim.map)
	gs:load_snapshot(sim:snapshot())
	expect(gs.structures[sam.sid] and gs.structures[sam.sid].shots and gs.structures[sam.sid].shots[1] == sim.tick, "the mirror's structure has them")
	gs:apply_delta({ t = sim.tick + 1, ev = { { Ev.STRUCT_SHOTS, sam.sid, { sim.tick, sim.tick + 1 } } } })
	expect(#gs.structures[sam.sid].shots == 2, "and follows Ev.STRUCT_SHOTS")
	F.advance(sim, 90)
	expect(sim:ready_missiles(sam, Rules.SAM_COOLDOWN_TICKS) == 2 and #sam.shots == 0, "both ready 90 ticks later")

	-- messages
	F.clear(sim)
	local B = F.owner(sim, "Bravo", Defs.KIND_HUMAN, 0)
	F.claim(sim, B, 760, 110, 4)
	expect(
		not sim:try_build(B, "city", F.tile(760, 110)) and F.has_msg(sim, "Not enough gold for a City", B),
		"Not enough gold for a City"
	)
	expect(
		not sim:try_build(B, "sam", F.tile(760, 110)) and F.has_msg(sim, "Not enough gold for a SAM Launcher", B),
		"Not enough gold for a SAM Launcher"
	)
	sim.o_gold[B] = 5000000
	expect(
		not sim:try_build(B, "city", c) and F.has_msg(sim, "You can only build on your own land", B),
		"not_own message"
	)
	expect(
		not sim:try_build(B, "port", F.tile(760, 110)) and F.has_msg(sim, "Ports must be built on your coast", B),
		"no_coast message"
	)
	expect(
		not sim:try_build(B, "bogus", F.tile(760, 110)) and not sim:try_build(B, "city", -5),
		"invalid kind / tile rejected"
	)
	-- crowd B's tiny land: a defense post (not upgradable) next to another has no room
	expect(sim:try_build(B, "defense", F.tile(760, 110)), "defense post on B's land")
	F.clear(sim)
	expect(
		not sim:try_build(B, "defense", F.tile(760, 111)) and F.has_msg(sim, "No room for a Defense Post there", B),
		"No room for a Defense Post there"
	)
	expect(sim:struct_total() == 4, "struct_total")
end

-- =============================================================================================
print("capture / destroy / defense cover")
do
	local sim = F.new_sim(2)
	local A = F.owner(sim, "Alpha", Defs.KIND_HUMAN, 50000000)
	local N2 = F.owner(sim, "Nation", Defs.KIND_NATION, 0)
	local T = F.owner(sim, "Tribe", Defs.KIND_TRIBE, 0)
	local c = F.claim(sim, A, 700, 120, 20)
	local ct = F.tile(700, 110)
	local dt = F.tile(700, 130)
	local pt = F.tile(712, 120)
	sim:add_struct(Defs.S_CITY, A, ct)
	sim:add_struct(Defs.S_DEFENSE, A, dt)
	sim:add_struct(Defs.S_FACTORY, A, pt)
	F.advance(sim, 50)
	sim:construction_tick()
	local post = sim.structs[2]
	expect(post.active, "post active after 50 ticks")
	local rf = Rules.defense_range()
	local inside, outside, bad = 0, 0, 0
	for _, t in sim:disk_tiles(dt, rf + 3, false) do
		local cov = buffer.readu8(sim.def_cover, t)
		if range_d2(dt, t) <= rf * rf then
			inside += 1
			if cov ~= 1 then
				bad += 1
			end
		elseif cov ~= 0 then
			bad += 1
		else
			outside += 1
		end
	end
	expect(bad == 0 and inside > 0 and outside > 0, "def_cover = 1 exactly within defense_range (geo metric)")
	expect(
		sim:_defense_post_covers(F.tile(700, 140), A) and not sim:_defense_post_covers(F.tile(700, 150), A),
		"_defense_post_covers in / out of range"
	)
	expect(not sim:_defense_post_covers(F.tile(700, 140), N2), "_defense_post_covers only for the post's owner")

	F.clear(sim)
	sim:set_owner(ct, N2)
	local so = F.events(sim, Ev.STRUCT_OWNER)
	expect(
		#so == 1 and so[1][2] == 1 and so[1][3] == N2 and sim.structs[1].owner == N2,
		"captured city changes hands (STRUCT_OWNER)"
	)
	expect(
		sim:struct_count(A, Defs.S_CITY) == 0 and sim:struct_count(N2, Defs.S_CITY) == 1 and sim.o_alevel[N2 * STRUCT_KINDS] == 1,
		"counts moved to the captor"
	)
	expect(F.has_msg(sim, "Nation captured your City", A), "capture message to the victim")
	F.clear(sim)
	sim:set_owner(dt, N2)
	expect(
		sim.structs[2] == nil
			and #F.events(sim, Ev.STRUCT_DEL) == 1
			and F.has_msg(sim, "Nation destroyed your Defense Post", A),
		"captured defense post is destroyed"
	)
	expect(buffer.readu8(sim.def_cover, F.tile(700, 140)) == 0, "cover removed with the post")
	F.clear(sim)
	sim:set_owner(pt, T)
	expect(
		sim.structs[3] ~= nil
			and sim.structs[3].owner == T
			and sim.structs[3].delete_at == 0
			and sim:struct_count(T, Defs.S_FACTORY) == 1
			and #F.events(sim, Ev.STRUCT_OWNER) == 1,
		"tribes capture structures too (they delete them later: tests/tribes_rules)"
	)
	sim:destroy_struct(sim.structs[3])
	-- factory capture by a nation: no message
	sim:add_struct(Defs.S_FACTORY, A, F.tile(690, 120))
	F.clear(sim)
	sim:set_owner(F.tile(690, 120), N2)
	expect(#F.msgs(sim) == 0 and #F.events(sim, Ev.STRUCT_OWNER) == 1, "captured factory changes hands silently")
	-- relinquish (nuke) destroys, no message
	sim:add_struct(Defs.S_CITY, A, F.tile(705, 125))
	F.clear(sim)
	sim:set_owner(F.tile(705, 125), 0)
	expect(#F.events(sim, Ev.STRUCT_DEL) == 1 and #F.msgs(sim) == 0, "unclaimed tile destroys its structure silently")
end

-- =============================================================================================
print("roads / trucks")
do
	local sim = F.new_sim(3)
	local A = F.owner(sim, "Alpha", Defs.KIND_HUMAN, 50000000)
	local B = F.owner(sim, "Bravo", Defs.KIND_NATION, 0)
	F.claim(sim, A, 700, 120, 30)
	-- cities first (no factory: no roads), then a factory 20 tiles away
	local c1 = sim:add_struct(Defs.S_CITY, A, F.tile(690, 120))
	local c2 = sim:add_struct(Defs.S_CITY, A, F.tile(690, 135))
	F.advance(sim, 20)
	sim:construction_tick()
	expect(#c1.roads == 0 and sim:road_total() == 0, "cities alone don't join the network")
	F.clear(sim)
	local f = sim:add_struct(Defs.S_FACTORY, A, F.tile(710, 125))
	F.advance(sim, 20)
	sim:construction_tick()
	local ra = F.events(sim, Ev.ROAD_ADD)
	expect(#ra >= 2 and sim:road_total() == #ra, "factory activation links stations (ROAD_ADD)")
	expect(#f.roads >= 1 and #c1.roads >= 1 and #c2.roads >= 1, "factory and both cities are stations")
	local okd = true
	for _, e in ra do
		local a, b = sim.structs[e[3]], sim.structs[e[4]]
		local d = math.sqrt(range_d2(a.tile, b.tile))
		if d < Rules.ROAD_MIN_TILES or d > Rules.ROAD_MAX_TILES then
			okd = false
		end
	end
	expect(okd, "road lengths within 15..110 source (7.7..56 tiles)")
	-- railroads are routed tile paths from one station to the other, shorter than railroadMaxSize
	local paths_ok = true
	for _, e in ra do
		local a, b, tiles = sim.structs[e[3]], sim.structs[e[4]], e[5]
		if type(tiles) ~= "table" or tiles[1] ~= a.tile or tiles[#tiles] ~= b.tile then
			paths_ok = false
			continue
		end
		if #tiles >= Rules.RAIL_MAX_PATH then
			paths_ok = false
		end
		for i = 2, #tiles do
			local W = F.W
			if math.abs(tiles[i] % W - tiles[i - 1] % W) > 1 or math.abs(tiles[i] // W - tiles[i - 1] // W) > 1 then
				paths_ok = false
			end
		end
	end
	expect(paths_ok, "railroads: connected tile paths station to station, under railroadMaxSize")
	-- a new station skips stations already within 4 hops: c2 links to c1, not to f again
	local direct = false
	for _, rid in c2.roads do
		if sim:road_other(rid, c2.sid) == f.sid then
			direct = true
		end
	end
	expect(sim:_hops(f, c2, 4) >= 1 and not (direct and #c2.roads > 1), "no link to a station already within 4 hops")
	-- a later city near the factory joins at once
	F.clear(sim)
	local c3 = sim:add_struct(Defs.S_CITY, A, F.tile(725, 115))
	F.advance(sim, 20)
	sim:construction_tick()
	expect(#c3.roads >= 1 and #F.events(sim, Ev.ROAD_ADD) >= 1, "city near a factory becomes a station")
	-- road rows sorted by rid
	local rows = sim:road_rows()
	local sorted = true
	for i = 2, #rows do
		if rows[i][1] <= rows[i - 1][1] then
			sorted = false
		end
	end
	expect(#rows == sim:road_total() and sorted, "road_rows in rid order")

	-- trucks: roll until the factory dispatches one
	local truck = nil
	for _ = 1, 5000 do
		F.advance(sim, 1)
		sim:factories_tick()
		for _, u in sim.unit_list do
			if not u.dead and u.kind == Defs.U_TRUCK then
				truck = u
			end
		end
		if truck then
			break
		end
	end
	expect(truck ~= nil, "factory dispatches a truck (1 / trainSpawnRate per tick)")
	if truck then
		local dest = sim.structs[truck.stops[#truck.stops]]
		expect(
			truck.stops[1] == f.sid and #truck.stops >= 2 and dest.kind == Defs.S_CITY and dest.cluster == f.cluster,
			"train: from the factory along the station route to a city of its cluster"
		)
		expect(
			truck.path[1] == f.tile and truck.tpt == Rules.TRUCK_TPT_X100 and truck.tpt == 50,
			"truck path from the factory at 50 ticks/tile x100 (2 full-size tiles per tick)"
		)
		local last_stop = sim.structs[truck.stops[#truck.stops]]
		expect(truck.path[#truck.path] == last_stop.tile, "path ends at the last stop")
		expect(
			truck.stop_ticks[#truck.stop_ticks] == truck.end_tick and truck.next_tick == truck.stop_ticks[2],
			"stop ticks / next_tick"
		)
		for i = 2, #truck.stops do
			local idx = truck.stop_idx[i]
			local st = sim.structs[truck.stops[i]]
			expect(
				truck.path[idx + 1] == st.tile
					and truck.stop_ticks[i] == truck.start_tick + (idx * truck.tpt + 99) // 100,
				"stop " .. i .. " index / tick"
			)
		end
		expect(f.trucks == 1 and sim.n_trucks == 1, "truck counters")
		-- run to arrival; count city stops
		local cities = 0
		for i = 2, #truck.stops do
			if sim.structs[truck.stops[i]].kind ~= Defs.S_FACTORY then
				cities += 1
			end
		end
		local acc0 = sim.o_bonus_acc[A]
		local g0 = sim.o_gold[A]
		F.clear(sim)
		while not truck.dead do
			F.advance(sim, 1)
			sim:units_tick()
		end
		expect(sim.tick == truck.end_tick, "truck removed at end_tick")
		expect(
			near(sim.o_gold[A] - g0, cities * Rules.train_gold("self", 0))
				and near(sim.o_bonus_acc[A] - acc0, cities * 10000),
			"own city stops pay trainGold self (10K) once each"
		)
		-- a person's stops are events for their map (a BONUS event: "+ 10.0K" over the station)
		local bonus = F.events(sim, Ev.BONUS)
		local at_stops = #bonus == cities
		local k = 0
		for i = 2, #truck.stops do
			local st = sim.structs[truck.stops[i]]
			if st.kind ~= Defs.S_FACTORY then
				k += 1
				local e = bonus[k]
				if e == nil or e[2] ~= A or e[3] ~= st.tile or e[4] ~= 10000 then
					at_stops = false
				end
			end
		end
		expect(at_stops and cities > 0, "each stop is a BONUS event for its owner: the station's tile, the gold")
		local del = F.events(sim, Ev.UNIT_DEL)
		expect(#del == 1 and del[1][2] == truck.uid and del[1][3] == Defs.DEL_ARRIVED, "UNIT_DEL arrived")
		-- nobody watches an AI's income: a nation, a bot player and a player who left get no event
		F.clear(sim)
		sim:add_bonus_gold(B, 25000, c1.tile)
		sim.o_ai[A] = 1
		sim:add_bonus_gold(A, 25000, c1.tile)
		sim.o_ai[A] = 0
		sim.o_left[A] = 1
		sim:add_bonus_gold(A, 25000, c1.tile)
		sim.o_left[A] = 0
		sim:add_bonus_gold(A, 25000)
		expect(#F.events(sim, Ev.BONUS) == 0, "no BONUS event for a nation, a bot player, a leaver, or gold without a place")
		sim:add_bonus_gold(A, 25000.4, c1.tile)
		local one = F.events(sim, Ev.BONUS)
		expect(#one == 1 and one[1][2] == A and one[1][3] == c1.tile and one[1][4] == 25000, "one for a person (whole gold)")
		sim.o_gold[A] -= 25000 * 3 + 25000.4
		sim.o_bonus_acc[A] -= 25000 * 3 + 25000.4
		F.clear(sim)
		expect(
			f.trucks == 0 and sim.n_trucks == 0 and sim:unit_total() == 0 and #sim.unit_list == 0,
			"truck counters released, unit_list compacted"
		)
	end
	-- foreign station pays both; hostile stations are skipped when routing
	expect(
		Rules.train_gold("ally", 0) == 35000
			and Rules.train_gold("other", 0) == 25000
			and Rules.train_gold("other", 12) == 10000
			and Rules.train_gold("self", 20) == 5000,
		"train_gold table"
	)
	-- destroying a station removes its roads (ROAD_DEL with both sids)
	F.clear(sim)
	local nroads = #f.roads
	local before = sim:road_total()
	sim:destroy_struct(f)
	local rd = F.events(sim, Ev.ROAD_DEL)
	expect(#rd == nroads and sim:road_total() == before - nroads, "destroy_struct removes the station's roads")
	local dangling = false
	for _, s in sim.structs do
		for _, rid in s.roads do
			if sim.roads[rid] == nil then
				dangling = true
			end
		end
	end
	expect(not dangling and #rd > 0 and #rd[1] == 4, "no dangling road ids; ROAD_DEL rid, sid_a, sid_b")
	expect(table.find(sim.factory_list, f) == nil, "factory removed from factory_list")
	-- a truck stopping at a foreign (non-hostile) city pays trainGold "other" to both owners
	local cb = sim:add_struct(Defs.S_CITY, B, F.tile(700, 150))
	sim:set_owner(cb.tile, B)
	cb.owner = B
	cb.station = true
	local SimStructures = require("../src/shared/Core/SimStructures")
	local u = SimStructures.Unit.new()
	u.kind = Defs.U_TRUCK
	u.owner = A
	u.stops = { c1.sid, cb.sid }
	u.stop_ticks = { sim.tick, sim.tick + 1 }
	u.stop_idx = { 0, 1 }
	u.path = { c1.tile, cb.tile }
	u.start_tick = sim.tick
	u.tpt = 97
	u.end_tick = sim.tick + 1
	u.next_stop = 2
	sim:add_unit(u)
	sim.n_trucks += 0
	local ga, gb = sim.o_gold[A], sim.o_gold[B]
	sim.o_alive[B] = 1
	F.advance(sim, 1)
	sim:_truck_tick(u)
	expect(
		near(sim.o_gold[A] - ga, 25000) and near(sim.o_gold[B] - gb, 25000) and u.dead,
		"foreign stop pays 25K to the truck's and the station's owner"
	)
	-- a station that won't trade (grudge) ends the trip there, unpaid
	local u2 = SimStructures.Unit.new()
	u2.kind = Defs.U_TRUCK
	u2.owner = A
	u2.stops = { c1.sid, cb.sid }
	u2.stop_ticks = { sim.tick, sim.tick + 1 }
	u2.stop_idx = { 0, 1 }
	u2.path = { c1.tile, cb.tile }
	u2.start_tick = sim.tick
	u2.tpt = 97
	u2.end_tick = sim.tick + 1
	u2.next_stop = 2
	sim:add_unit(u2)
	sim.grudge[B * 1024 + A] = sim.tick + 1000
	local ga2 = sim.o_gold[A]
	F.advance(sim, 1)
	sim:_truck_tick(u2)
	expect(u2.dead and near(sim.o_gold[A] - ga2, 0), "a hostile station ends the train unpaid")
end

-- =============================================================================================
print("railroads snap (connectToExistingRails)")
do
	local sim = F.new_sim(5)
	local A = F.owner(sim, "Alpha", Defs.KIND_HUMAN, 50000000)
	F.claim(sim, A, 700, 120, 30)
	local c1 = sim:add_struct(Defs.S_CITY, A, F.tile(690, 120))
	F.advance(sim, 20)
	sim:construction_tick()
	local f = sim:add_struct(Defs.S_FACTORY, A, F.tile(712, 120))
	F.advance(sim, 20)
	sim:construction_tick()
	expect(#c1.roads == 1 and #f.roads == 1, "factory and city linked by one railroad")
	local rid = c1.roads[1]
	local tiles = sim.roads[rid][3]
	-- a city right beside the middle of that railroad joins it instead of laying its own
	local mid = tiles[#tiles // 2]
	F.clear(sim)
	local c2 = sim:add_struct(Defs.S_CITY, A, mid + 1)
	F.advance(sim, 20)
	sim:construction_tick()
	local del = F.events(sim, Ev.ROAD_DEL)
	local add = F.events(sim, Ev.ROAD_ADD)
	expect(#del == 1 and del[1][2] == rid, "the railroad is split")
	expect(
		#add == 2 and #c2.roads == 2 and (add[1][4] == c2.sid or add[1][3] == c2.sid) and (add[2][3] == c2.sid),
		"into two railroads through the new station"
	)
	local total = #add[1][5] + #add[2][5]
	expect(total == #tiles, "the halves keep every tile of the railroad")
	expect(sim:_hops(c1, f, 4) == 2, "c1 - c2 - f")
	sim:_ensure_clusters()
	expect(c1.cluster ~= 0 and c1.cluster == f.cluster and c2.cluster == f.cluster, "one cluster")
	-- destroying the middle station splits the network
	sim:destroy_struct(c2)
	sim:_ensure_clusters()
	expect(#c1.roads == 0 and #f.roads == 0 and c1.cluster ~= f.cluster, "removing a station splits clusters")
end

-- =============================================================================================
print("snapshot rows / units registry")
do
	local sim = F.new_sim(4)
	local A = F.owner(sim, "Alpha", Defs.KIND_NATION, 50000000)
	F.claim(sim, A, 700, 120, 20)
	sim:add_struct(Defs.S_CITY, A, F.tile(700, 120))
	sim:add_struct(Defs.S_SILO, A, F.tile(700, 131))
	sim:add_struct(Defs.S_CITY, A, F.tile(711, 120))
	sim:destroy_struct(sim.structs[2])
	local rows = sim:struct_rows()
	expect(
		#rows == 2 and rows[1][1] == 1 and rows[2][1] == 3 and #rows[1] == 6,
		"struct_rows skip destroyed, sid order, 6 fields"
	)
	local br = sim:built_rows()
	expect(
		#br == 1 and br[1][1] == A and #br[1] == 1 + Rules.BUILT_SLOTS and br[1][2] == 2 and br[1][7] == 1,
		"built_rows [owner, one count per slot]"
	)
	expect(sim:struct_total() == 2, "struct_total after destroy")
	local SimStructures = require("../src/shared/Core/SimStructures")
	local u = SimStructures.Unit.new()
	u.kind = Defs.U_TRANSPORT
	u.owner = A
	u.path = { 10, 11, 12, 13 }
	u.start_tick = sim.tick
	u.tpt = 195
	u.end_tick = sim.tick + (3 * 195 + 99) // 100
	u.troops = 1234.9
	sim.o_boats[A] += 1
	F.clear(sim)
	sim:add_unit(u)
	local ua = F.events(sim, Ev.UNIT_ADD)
	expect(
		#ua == 1 and ua[1][2] == u.uid and ua[1][5] == u.path and ua[1][8] == 1234,
		"UNIT_ADD uid, kind, owner, path, start, tpt, int(troops)"
	)
	expect(u.next_tick == u.end_tick, "next_tick = end_tick for non-warships")
	expect(sim:unit_tile(u) == 10, "unit_tile at start")
	F.advance(sim, 2)
	expect(sim:unit_tile(u) == 11, "unit_tile after 2 ticks (tpt 195)")
	F.advance(sim, 100)
	expect(sim:unit_tile(u) == 13, "unit_tile clamps at the end")
	expect(sim:count_units_of(A, Defs.U_TRANSPORT) == 1, "count_units_of")
	local ur = sim:unit_rows()
	expect(#ur == 1 and #ur[1] == 12 and ur[1][7] == 1234 and ur[1][12] == -1, "unit_rows (12 fields)")
	sim:remove_unit(u, Defs.DEL_DESTROYED)
	sim:remove_unit(u, Defs.DEL_DESTROYED)
	expect(
		sim.o_boats[A] == 0 and #F.events(sim, Ev.UNIT_DEL) == 1,
		"remove_unit is idempotent, releases the boat slot"
	)
	sim:compact_units()
	expect(#sim.unit_list == 0 and sim:unit_total() == 0, "compact_units")
end

-- =============================================================================================
print("bulk upgrades (an amount per order)")
do
	-- 2026-09-29: the build menu offers several levels of a city, factory or SAM at once, on top of one
	-- already built, when you can afford them
	local sim = F.new_sim(3)
	local A = F.owner(sim, "Alpha", Defs.KIND_HUMAN, 100000000)
	local c = F.claim(sim, A, 700, 120, 15)
	expect(sim:try_build(A, "city", c), "a city")
	local city = sim.structs[1]
	F.advance(sim, 20)
	sim:construction_tick()
	-- five more levels at once: each at the next price (counts 1..5: 250K, 500K, 1M, 1M, 1M)
	local g0 = sim.o_gold[A]
	local want = 0
	for i = 1, 5 do
		want += Rules.build_cost("city", i)
	end
	sim:_apply_intent(A, { type = "build", kind = "city", tile = c, amount = 5 })
	expect(city.level == 6 and #sim.struct_list == 1, "amount 5 on a city: level 6, no new structure")
	expect(near(g0 - sim.o_gold[A], want), "each level at the next price")
	-- short of gold: it stops at what it can afford
	sim.o_gold[A] = Rules.build_cost("city", 6) + Rules.build_cost("city", 7) + 10
	sim:_apply_intent(A, { type = "build", kind = "city", tile = c, amount = 10 })
	expect(city.level == 8, "stops once the next level is unaffordable")
	-- on empty land an amount builds one structure only (bulk is for upgrades)
	sim.o_gold[A] = 100000000
	local far = F.claim(sim, A, 740, 140, 10)
	sim:_apply_intent(A, { type = "build", kind = "factory", tile = far, amount = 5 })
	local fac = 0
	for _, st in sim.struct_list do
		if st.kind == Defs.S_FACTORY then
			fac += 1
			expect(st.level == 1, "the new factory stays level 1")
		end
	end
	expect(fac == 1, "one new factory")
end

F.finish("simsys_structures")
