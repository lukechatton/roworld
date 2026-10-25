-- sim-systems: SimWarships tests (build, patrol, targeting, shells, veterancy, retreat / dock /
-- heal, trade-ship capture, manual moves, defense-post fire). Run: .bin/lune run tests/simsys_warships.luau
local F = require("./simsys_fixture")
local Defs, Ev, Rules = F.Defs, F.Ev, F.Rules
local expect, near = F.expect, F.near
local SimStructures = require("../src/shared/Core/SimStructures")

local range_d2 = F.map.range_d2
local W = F.W
local COAST = F.coast_tiles()

local function coast_of(sim, id: number): { number }
	local out = {}
	for _, t in COAST do
		if buffer.readi32(sim.owner, t * 4) == id and sim.map:coast_body_of(t) == 1 then
			table.insert(out, t)
		end
	end
	return out
end

-- Open-sea tile (not shore) of body 1 nearest to (x, y).
local function open_sea(sim, x: number, y: number): number
	local best, bd = -1, math.huge
	for dy = -20, 20 do
		for dx = -30, 30 do
			local t = F.tile(x + dx, y + dy)
			if
				buffer.readu8(sim.map.terrain, t) == Defs.T_OCEAN
				and buffer.readu8(sim.shore_water, t) == 0
				and buffer.readi32(sim.nav.region, t * 4) >= 0
			then
				local d = F.map.dist2(t, F.tile(x, y))
				if d < bd then
					bd = d
					best = t
				end
			end
		end
	end
	return best
end

local function setup(seed)
	local sim = F.new_sim(seed)
	local A = F.owner(sim, "Alpha", Defs.KIND_HUMAN, 10000000, 20000)
	local B = F.owner(sim, "Bravo", Defs.KIND_HUMAN, 10000000, 20000)
	F.claim(sim, A, 497, 146, 7)
	F.claim(sim, B, 500, 159, 7)
	local pa = sim:add_struct(Defs.S_PORT, A, coast_of(sim, A)[1])
	local pb = sim:add_struct(Defs.S_PORT, B, coast_of(sim, B)[1])
	F.advance(sim, 50)
	sim:construction_tick()
	return sim, A, B, pa, pb
end

local function new_unit(sim, kind, owner, path, tpt)
	local u = SimStructures.Unit.new()
	u.kind = kind
	u.owner = owner
	u.path = path
	u.start_tick = sim.tick
	u.tpt = tpt or 100
	u.end_tick = sim.tick + ((#path - 1) * u.tpt + 99) // 100
	if kind == Defs.U_TRANSPORT then
		sim.o_boats[owner] += 1
	end
	sim:add_unit(u)
	return u
end

-- =============================================================================================
print("build / events / costs / orders")
do
	local sim, A, B, pa = setup(1)
	-- shore water ring
	local shore_ok = true
	for _, c in COAST do
		local x = c % W
		if x < W - 1 then
			local n = c + 1
			if buffer.readu8(sim.map.terrain, n) <= Defs.T_LAKE and buffer.readu8(sim.shore_water, n) ~= 1 then
				shore_ok = false
			end
		end
	end
	expect(shore_ok, "shore_water marks water 4-adjacent to coast tiles")
	local sea = open_sea(sim, 505, 153)
	expect(sea >= 0, "open sea tile found")
	F.clear(sim)
	local g0 = sim.o_gold[A]
	expect(sim:build_warship(A, sea), "build_warship")
	local w = sim.warship_list[1]
	expect(
		w ~= nil and w.kind == Defs.U_WARSHIP and w.path[1] == pa.water and #w.path == 1,
		"spawns at the port's water tile"
	)
	expect(
		w.patrol == sea and w.hp == 1000 and w.max_hp == 1000 and w.tpt == 100,
		"patrols the clicked sea tile, 1000 HP"
	)
	expect(near(g0 - sim.o_gold[A], 250000), "first warship 250K")
	expect(sim.o_warships[A] == 1 and sim.o_built[A * 16 + Rules.BUILT_WARSHIP] == 1, "warship counters")
	local seq = {}
	for _, e in sim.d_ev do
		table.insert(seq, e[1])
	end
	expect(seq[1] == Ev.UNIT_ADD and seq[2] == Ev.UNIT_HP and seq[3] == Ev.UNIT_STATE, "UNIT_ADD, UNIT_HP, UNIT_STATE")
	local st = F.events(sim, Ev.UNIT_STATE)[1]
	expect(st[2] == w.uid and st[3] == 0 and st[4] == sea, "UNIT_STATE uid, 0 patrolling, patrol tile")
	expect(w.next_tick == 1073741824, "warships never due in units_tick")
	-- land click: any own port, patrol stays at the port water
	g0 = sim.o_gold[A]
	expect(
		sim:build_warship(A, F.tile(497, 140)) and sim.warship_list[2].patrol == pa.water,
		"land click: from any port, patrol at the port"
	)
	expect(near(g0 - sim.o_gold[A], 500000), "second warship 500K")
	F.clear(sim)
	local C2 = F.owner(sim, "Charlie", Defs.KIND_HUMAN, 10000000)
	expect(
		not sim:build_warship(C2, sea) and F.has_msg(sim, "You need a port on that sea to build warships", C2),
		"no port message"
	)
	sim.o_gold[B] = 0
	expect(not sim:build_warship(B, sea) and F.has_msg(sim, "Not enough gold for a Warship", B), "gold message")
	expect(sim:try_build(A, "warship", sea), "try_build('warship') routes to build_warship")

	-- move_warship
	F.clear(sim)
	local sea2 = open_sea(sim, 515, 153)
	expect(not sim:move_warship(B, w.uid, sea2), "only the owner can move it")
	expect(not sim:move_warship(A, w.uid, F.tile(497, 146)), "land rejected")
	expect(
		sim:move_warship(A, w.uid, sea2) and w.patrol == sea2 and w.manual_tick == sim.tick and w.target_tile == -1,
		"move_warship sets patrol + manual tick"
	)
	expect(#F.events(sim, Ev.UNIT_STATE) == 1, "UNIT_STATE on move")

	-- patrol: a course inside the patrol box
	F.clear(sim)
	F.advance(sim, 1)
	sim:warships_tick()
	local up = nil
	for _, e in F.events(sim, Ev.UNIT_PATH) do
		if e[2] == w.uid then
			up = e
		end
	end
	expect(up ~= nil and up[3] == w.path and up[4] == sim.tick and up[5] == 100, "UNIT_PATH uid, path, start_tick, tpt")
	local half = Rules.WARSHIP_PATROL_FULL / Rules.K_LIN / 2
	local tt = w.target_tile
	expect(
		tt >= 0
			and math.abs(tt // W - sea2 // W) <= half * 3.375 + 1
			and buffer.readu8(sim.map.terrain, tt) <= Defs.T_LAKE,
		"patrol target is water near the patrol tile"
	)
	expect(w.path[#w.path] == tt and w.path[1] == pa.water, "course from the current position to the target")
end

-- =============================================================================================
print("targeting / shells / veterancy")
do
	local sim, A, B, pa, pb = setup(2)
	local sea = open_sea(sim, 505, 153)
	sim:build_warship(A, sea)
	local w = sim.warship_list[1]
	-- put the warship at sea
	w.path = { sea }
	w.start_tick = sim.tick
	-- an enemy transport sailing past, a trade ship and an enemy warship
	local tr = new_unit(sim, Defs.U_TRANSPORT, B, { sea + 3, sea + 4, sea + 5, sea + 6, sea + 7, sea + 8 })
	tr.troops = 5000
	local wb = new_unit(sim, Defs.U_WARSHIP, B, { sea - 2 })
	wb.hp, wb.max_hp = 1000, 1000
	wb.shelled = {}
	sim.o_warships[B] += 1
	local tgt = sim:_find_target(w, sea, true)
	expect(tgt == tr, "transport has priority over warships")
	-- scan tick
	while (sim.tick + w.uid) % 3 ~= 0 do
		F.advance(sim, 1)
	end
	F.clear(sim)
	sim:warships_tick()
	local sh = F.events(sim, Ev.SHELL)
	local shell = sh[1]
	expect(
		#sh >= 1 and shell[3] == 0 and shell[4] == w.uid and shell[5] == sea and shell[6] == tr.uid,
		"SHELL id, 0 warship, shooter uid, from tile, target"
	)
	local dist = math.sqrt(range_d2(sea, sim:unit_tile(tr)))
	expect(
		shell[7] == sim.tick and shell[8] == sim.tick + Rules.shell_flight_ticks(dist),
		"fire tick / impact tick (3 full-size tiles per tick)"
	)
	local okd = false
	for r = 1, 5 do
		if shell[9] == Rules.shell_damage(r, 0) then
			okd = true
		end
	end
	expect(okd and shell[9] >= 200 and shell[9] <= 300, "damage 200..300")
	expect(
		w.shelled[tr.uid] == true and w.last_shot < sim.tick,
		"transport marked shelled; no reload after a transport shell"
	)
	expect(#sim.shells == 1 and sim:shell_rows()[1][1] == shell[2], "shell_rows")
	-- same tick+1: shelled transport is skipped, the warship is next (no reload after transports)
	local t2 = sim:_find_target(w, sea, true)
	expect(t2 == wb, "then the warship")
	-- impact
	while sim.tick < shell[8] do
		F.advance(sim, 1)
		F.clear(sim)
		sim:warships_tick()
	end
	expect(tr.dead, "transport sunk at impact")
	expect(
		F.has_msg(sim, "Alpha's warship sank your transport", B)
			and F.has_msg(sim, "Your warship sank a transport from Bravo", A),
		"sink messages"
	)
	local del = nil
	for _, e in F.events(sim, Ev.UNIT_DEL) do
		if e[2] == tr.uid then
			del = e
		end
	end
	expect(del ~= nil and del[3] == Defs.DEL_DESTROYED, "UNIT_DEL destroyed")
	expect(w.vet_progress == Rules.WARSHIP_VET_TRADES and w.vet == 0, "transport kill: +25 of 250 veterancy points")
	local hk = false
	for _, h in sim.hooks do
		if h[1] == "sunk" and h[2] == tr.uid and h[3] == A then
			hk = true
		end
	end
	expect(hk, "_on_transport_sunk(u, killer)")
	-- warship duel until one sinks
	local shells_at_b = 0
	local last_fire = -1000
	local gap_ok = true
	for _ = 1, 3000 do
		F.advance(sim, 1)
		F.clear(sim)
		-- keep both ships in place
		w.path = { sea }
		w.start_tick = sim.tick
		w.target_tile = sea
		w.end_tick = sim.tick + 1000
		wb.path = { sea - 2 }
		wb.start_tick = sim.tick
		wb.target_tile = sea - 2
		wb.end_tick = sim.tick + 1000
		sim:warships_tick()
		for _, e in F.events(sim, Ev.SHELL) do
			if e[4] == w.uid then
				shells_at_b += 1
				if e[7] - last_fire <= Rules.WARSHIP_FIRE_TICKS then
					gap_ok = false
				end
				last_fire = e[7]
			end
		end
		if wb.dead or w.dead then
			break
		end
	end
	expect(wb.dead or w.dead, "duel ends with a sinking")
	expect(gap_ok and shells_at_b >= 1, "warship shells at warships > 20 ticks apart")
	local winner = if wb.dead then w else wb
	expect(
		winner.vet == 1 and winner.vet_progress == 0 and winner.max_hp == 1200,
		"sinking a warship: +1 veterancy at once, max HP 1200"
	)
	-- veterancy meter
	local v = new_unit(sim, Defs.U_WARSHIP, A, { sea })
	v.hp, v.max_hp = 1000, 1000
	F.clear(sim)
	for _ = 1, 9 do
		sim:_vet_progress(v, Rules.WARSHIP_VET_TRADES)
	end
	expect(v.vet == 0 and v.vet_progress == 225, "9 transports: no level yet")
	sim:_vet_progress(v, Rules.WARSHIP_VET_TRADES)
	expect(
		v.vet == 1
			and v.vet_progress == 0
			and #F.events(sim, Ev.UNIT_VET) == 1
			and F.events(sim, Ev.UNIT_VET)[1][3] == 1,
		"10 transports = +1 level (UNIT_VET)"
	)
	for _ = 1, 25 do
		sim:_vet_progress(v, Rules.WARSHIP_VET_TRANSPORTS)
	end
	expect(v.vet == 2 and v.max_hp == 1400, "25 trade captures = +1 level")
	v.vet = 3
	sim:_vet_progress(v, 1000)
	expect(v.vet == 3 and v.vet_progress == 0, "capped at 3")
	expect(
		Rules.shell_damage(5, 3) == 480 and Rules.shell_damage(1, 0) == 200 and Rules.shell_damage(3, 1) == 300,
		"shell damage scales +20 %/level"
	)
	-- UNIT_HP at most once per unit per tick
	local cnt = {}
	F.clear(sim)
	v.hp = 500
	sim:_mark_hp(v.uid)
	sim:_mark_hp(v.uid)
	F.advance(sim, 1)
	sim:warships_tick()
	for _, e in F.events(sim, Ev.UNIT_HP) do
		cnt[e[2]] = (cnt[e[2]] or 0) + 1
	end
	local once = true
	for _, n in cnt do
		if n > 1 then
			once = false
		end
	end
	expect(once and cnt[v.uid] == 1, "UNIT_HP once per unit per tick")
	local _ = pb
	_ = pa
end

-- =============================================================================================
print("retreat / dock / heal")
do
	local sim, A, B, pa = setup(3)
	local sea = open_sea(sim, 505, 153)
	sim:build_warship(A, sea)
	local w = sim.warship_list[1]
	w.path = { sea }
	w.start_tick = sim.tick
	w.hp = 700
	sim:_mark_hp(w.uid)
	F.advance(sim, 1)
	F.clear(sim)
	sim:warships_tick()
	expect(w.state == 1 and w.retreat_port == pa.sid, "below 75 %: retreat to the nearest own port")
	local st = F.events(sim, Ev.UNIT_STATE)
	expect(#st >= 1 and st[1][3] == 1, "UNIT_STATE retreating")
	expect(w.target_tile == pa.water and w.path[#w.path] == pa.water, "course for the port's water tile")
	local docked_at = nil
	local passive_seen = false
	for _ = 1, 2000 do
		F.advance(sim, 1)
		F.clear(sim)
		local before = w.hp
		sim:warships_tick()
		if w.state == 1 and w.near_port and w.hp == before + 1 then
			passive_seen = true
		end
		if w.state == 2 and docked_at == nil then
			docked_at = sim.tick
			local p = F.events(sim, Ev.UNIT_PATH)
			expect(#p >= 1 and #p[#p][3] == 1, "docking stops the ship (1-tile UNIT_PATH)")
			local d = Rules.WARSHIP_DOCK_FULL / Rules.K_LIN
			expect(range_d2(sim:unit_tile(w), pa.tile) <= d * d, "docks within 5 full-size tiles of the port")
		end
		if docked_at and w.state == 0 then
			break
		end
	end
	expect(passive_seen, "+1 HP/tick near an own port")
	expect(docked_at ~= nil and w.state == 0 and w.hp == w.max_hp, "heals docked and resumes patrol when full")
	-- a port docks `level` ships: the second damaged ship waits (or picks another port)
	sim:build_warship(A, sea)
	sim:build_warship(A, sea)
	local w2, w3 = sim.warship_list[2], sim.warship_list[3]
	w2.state, w2.retreat_port = 2, pa.sid
	expect(sim:_docked_at(pa, nil) == 1 and sim:_docked_at(pa, w2) == 0, "_docked_at counts docked ships (exclude)")
	expect(
		sim:_nearest_port(w3, sea, true, nil) == nil and sim:_nearest_port(w3, sea, false, nil) == pa,
		"full port unavailable"
	)
	-- docked heal share: level x 5 HP per tick split between docked ships
	w2.hp = 500
	w2.heal_rem = 0
	w2.near_port_tick = sim.tick + 100
	w2.near_port = false
	sim:_heal(w2, sim:unit_tile(w2))
	expect(w2.hp == 505, "docked: port level x 5 HP per tick")
	-- no retreat within 50 ticks of a manual move
	w3.hp = 100
	w3.manual_tick = sim.tick
	expect(not sim:_should_retreat(w3, 100), "no retreat right after a manual move")
	w3.manual_tick = -100000
	expect(sim:_should_retreat(w3, 749) and not sim:_should_retreat(w3, 750), "retreat threshold 75 %")
	local _ = B
end

-- =============================================================================================
print("trade-ship hunting / capture")
do
	local sim, A, B, pa, pb = setup(4)
	local sea = open_sea(sim, 520, 147)
	sim:build_warship(A, sea)
	local w = sim.warship_list[1]
	w.path = { sea }
	w.start_tick = sim.tick
	-- B's trade ship in open water, bound for a third owner's port
	local C2 = F.owner(sim, "Charlie", Defs.KIND_HUMAN, 0)
	local pc = SimStructures.Struct.new()
	pc.sid = 999
	pc.kind = Defs.S_PORT
	pc.owner = C2
	sim.structs[999] = pc
	local path = {}
	for x = 512, 532 do
		table.insert(path, F.tile(x, 147))
	end
	local ok_open = true
	for _, t in path do
		if buffer.readu8(sim.shore_water, t) == 1 or buffer.readu8(sim.map.terrain, t) > 1 then
			ok_open = false
		end
	end
	local v = new_unit(sim, Defs.U_TRADE, B, path)
	v.src_sid = pb.sid
	v.dst_sid = 999
	expect(ok_open, "trade path in open water")
	expect(
		sim:_find_target(w, sea, true) == v,
		"trade ship targeted (own port on this water, not safe, foreign destination)"
	)
	expect(sim:_find_target(w, sea, false) == nil, "include_trade=false skips trade ships")
	v.dst_sid = pa.sid
	expect(sim:_find_target(w, sea, true) == nil, "not when bound for the warship owner's port")
	v.dst_sid = 999
	w.patrol = F.tile(600, 147)
	expect(sim:_find_target(w, sea, true) == nil, "only within 100 source of the patrol tile")
	w.patrol = sea
	-- hunt: course at 2 full-size tiles per tick
	F.clear(sim)
	sim:_hunt(w, v, sea)
	expect(
		w.hunt_uid == v.uid and w.target_tile == -2 and w.tpt == Rules.WARSHIP_HUNT_TPT_X100 and w.tpt == 50,
		"hunt course at 50 ticks/tile x100"
	)
	-- capture within 5 full-size tiles (manhattan)
	local vpos = sim:unit_tile(v)
	F.clear(sim)
	sim:_capture_trade(w, v, vpos)
	local del = F.events(sim, Ev.UNIT_DEL)
	expect(#del == 1 and del[1][2] == v.uid and del[1][3] == Defs.DEL_CAPTURED, "UNIT_DEL captured")
	local add = F.events(sim, Ev.UNIT_ADD)
	local nu = sim.unit_list[#sim.unit_list]
	expect(
		#add == 1 and nu.kind == Defs.U_TRADE and nu.owner == A and nu.orig_owner == B and nu.dst_sid == pa.sid,
		"new trade ship for the captor, bound for its port"
	)
	expect(nu.path[1] == vpos and nu.path[#nu.path] == pa.water, "from the capture point to the captor's port")
	expect(w.vet_progress == Rules.WARSHIP_VET_TRANSPORTS, "capture: +10 veterancy points")
	expect(
		F.has_msg(sim, "Alpha's warships are capturing your trade ships", B)
			and F.has_msg(sim, "Your warship captured a trade ship from Bravo", A),
		"capture messages"
	)
	local hk = false
	for _, h in sim.hooks do
		if h[1] == "captured" and h[2] == B and h[3] == A and h[4] == vpos then
			hk = true
		end
	end
	expect(hk, "_on_trade_captured(victim, captor, tile)")
	-- captured ship arriving at the captor's port pays the captor alone
	local ga, gb = sim.o_gold[A], sim.o_gold[B]
	sim.tick = nu.end_tick
	sim:_trade_arrive(nu)
	expect(
		near(sim.o_gold[A] - ga, Rules.trade_gold(nu.traveled + #nu.path)) and near(sim.o_gold[B], gb),
		"captured cargo pays the captor only"
	)
	-- safe from pirates along the shore
	local shore = {}
	for _, t in COAST do
		local n = if t % W < W - 1 then t + 1 else t - 1
		if buffer.readu8(sim.shore_water, n) == 1 then
			table.insert(shore, n)
			break
		end
	end
	local v2 = new_unit(sim, Defs.U_TRADE, B, { shore[1], shore[1] })
	expect(sim:_safe_from_pirates(v2), "a trade ship on shore water is safe")
end

-- =============================================================================================
print("defense posts (optional)")
do
	local sim, A, B = setup(5)
	sim.defense_posts_shoot = true
	local post = sim:add_struct(Defs.S_DEFENSE, A, coast_of(sim, A)[3])
	F.advance(sim, 50)
	sim:construction_tick()
	local near_sea = sim.nav:water_next_to(post.tile, 1)
	local tr = new_unit(sim, Defs.U_TRANSPORT, B, { near_sea, near_sea })
	while sim.tick % 10 ~= 0 do
		F.advance(sim, 1)
	end
	F.clear(sim)
	sim:warships_tick()
	local sh = F.events(sim, Ev.SHELL)
	expect(
		#sh == 1 and sh[1][3] == 1 and sh[1][4] == post.sid and sh[1][6] == tr.uid,
		"post shells a transport (shooter_kind 1)"
	)
	F.advance(sim, 10)
	F.clear(sim)
	sim:warships_tick()
	expect(#F.events(sim, Ev.SHELL) == 0, "then reloads for 100 ticks")
	local _ = B
end

F.finish("simsys_warships")
