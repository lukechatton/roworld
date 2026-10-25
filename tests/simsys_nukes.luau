-- sim-systems: SimNukes tests (silo launch, flight, blasts, fallout, troop loss, SAM planning and
-- interception, MIRV split, alliance breaks). Run: .bin/lune run tests/simsys_nukes.luau
local F = require("./simsys_fixture")
local Defs, Ev, Rules = F.Defs, F.Ev, F.Rules
local expect, near = F.expect, F.near

local range_d2 = F.map.range_d2
local geo_manhattan = F.map.geo_manhattan
local tile_distance = F.map.gc_dist
local W = F.W

local function owned(sim, t)
	return buffer.readi32(sim.owner, t * 4)
end

local function run_nukes_until(sim, cond, max_ticks)
	for _ = 1, max_ticks or 1000 do
		F.advance(sim, 1)
		sim:nukes_tick()
		if cond() then
			return true
		end
	end
	return false
end

-- A (silo) in Kazakhstan, B (victim) east of it.
local function setup(seed)
	local sim = F.new_sim(seed)
	local A = F.owner(sim, "Alpha", Defs.KIND_HUMAN, 100000000, 100000)
	local B = F.owner(sim, "Bravo", Defs.KIND_HUMAN, 100000000, 100000)
	F.claim(sim, A, 690, 100, 10)
	F.claim(sim, B, 760, 110, 25)
	sim.o_cap[A] = 500000
	sim.o_cap[B] = 500000
	local silo = sim:add_struct(Defs.S_SILO, A, F.tile(690, 100))
	return sim, A, B, silo
end

-- =============================================================================================
print("launch validation / flight")
do
	local sim, A, B, silo = setup(1)
	local t = F.tile(760, 110)
	F.clear(sim)
	expect(
		not sim:launch_nuke(A, "atom", F.tile(690, 101)) and F.has_msg(sim, "You can't nuke your own land", A),
		"own land"
	)
	expect(
		not sim:launch_nuke(A, "atom", t) and F.has_msg(sim, "No missile silo is ready", A),
		"silo under construction"
	)
	expect(
		not sim:launch_nuke(A, "warhead", t) and not sim:launch_nuke(A, "bogus", t),
		"warhead / unknown kinds rejected"
	)
	F.advance(sim, 100)
	sim:construction_tick()
	expect(silo.active, "silo active after 10 s")
	sim:form_alliance(A, B)
	F.clear(sim)
	expect(not sim:launch_nuke(A, "atom", t) and F.has_msg(sim, "You can't nuke an ally", A), "ally")
	sim:end_alliance(A, B, 0)
	sim.o_gold[A] = 100
	F.clear(sim)
	expect(
		not sim:launch_nuke(A, "atom", t) and F.has_msg(sim, "Not enough gold for an Atom Bomb", A),
		"gold message (an Atom Bomb)"
	)
	sim.o_gold[A] = 100000000
	F.clear(sim)
	expect(sim:launch_nuke(A, "atom", t), "launch atom")
	local n = sim.nukes[1]
	-- the nuke flies the Bezier arc at 10 full-size tiles per tick: the flight is the arc's length / 10
	local arc = sim.R.nuke_arc(W, F.H, silo.tile, t)
	local flight = sim.R.nuke_arc_ticks(arc, Defs.N_ATOM)
	expect(
		n.flight == flight
			and flight == math.max(1, math.ceil(arc.length * sim.R.K_LIN / 10))
			and arc.length >= tile_distance(silo.tile, t) - 1e-6,
		"flight = the arc's length / 10 full-size tiles per tick"
	)
	local ne = F.events(sim, Ev.NUKE)[1]
	expect(
		ne[2] == n.uid
			and ne[3] == Defs.N_ATOM
			and ne[4] == A
			and ne[5] == silo.tile
			and ne[6] == t
			and ne[7] == sim.tick
			and ne[8] == flight,
		"NUKE uid, kind, owner, from, to, launch_tick, flight"
	)
	expect(near(sim.o_gold[A], 100000000 - 750000), "atom costs 750K")
	expect(
		sim.nukes_launched == 1 and #silo.shots == 1 and sim:ready_missiles(silo, 90) == 0,
		"silo reloading (level 1 = 1 missile)"
	)
	expect(sim:grudge_of(B, A) and sim.o_attacked_tick[B] == sim.tick, "grudge and attacked tick")
	expect(
		F.has_msg(sim, "Alpha launched an Atom Bomb at you!", B) and F.has_msg(sim, "Atom Bomb launched at Bravo", A),
		"launch messages"
	)
	F.clear(sim)
	expect(not sim:launch_nuke(A, "atom", t) and F.has_msg(sim, "No missile silo is ready", A), "cooldown 9 s")
	F.advance(sim, 89)
	expect(sim:ready_missiles(silo, 90) == 0, "still reloading at 89 ticks")
	F.advance(sim, 1)
	expect(sim:ready_missiles(silo, 90) == 1, "ready after 90 ticks")
	expect(#sim:nuke_rows() == 1 and sim:nuke_rows()[1][7] == flight, "nuke_rows")
end

-- =============================================================================================
print("atom blast / fallout / troop loss")
do
	local sim, A, B, silo = setup(2)
	F.advance(sim, 100)
	sim:construction_tick()
	local t = F.tile(760, 110)
	-- structures / units of B around the target
	local s_in = sim:add_struct(Defs.S_CITY, B, F.tile(760, 120)) -- 10 tiles: inside outer 15.36
	local s_out = sim:add_struct(Defs.S_CITY, B, F.tile(760, 128)) -- 18 tiles: outside
	local tiles_before = sim.o_tiles[B]
	local troops_before = sim.o_troops[B]
	expect(sim:launch_nuke(A, "atom", t), "launch")
	local n = sim.nukes[1]
	F.clear(sim)
	local exploded = run_nukes_until(sim, function()
		return n.dead
	end, 500)
	expect(exploded and sim.tick == n.launch_tick + n.flight, "detonates at launch_tick + flight")
	local inner, outer = Rules.nuke_radii(Defs.N_ATOM)
	expect(near(inner, 12 / Rules.K_LIN, 1e-5) and near(outer, 30 / Rules.K_LIN, 1e-5), "atom radii 12 / 30")
	local boom = F.events(sim, Ev.BOOM)[1]
	expect(
		boom[2] == n.uid and boom[3] == Defs.N_ATOM and boom[4] == t and boom[5] == math.ceil(outer) and boom[6] == A,
		"BOOM uid, kind, tile, ceil(outer), owner"
	)
	local in_all, ring, ring_hit, bad = 0, 0, 0, 0
	for _, c in sim:disk_tiles(t, outer, true) do
		local fo = bit32.band(buffer.readu8(sim.flags, c), 1) == 1
		if range_d2(t, c) <= inner * inner then
			in_all += 1
			if not fo or owned(sim, c) ~= 0 then
				bad += 1
			end
		else
			ring += 1
			if fo then
				ring_hit += 1
				if owned(sim, c) ~= 0 then
					bad += 1
				end
			elseif owned(sim, c) ~= B then
				bad += 1
			end
		end
	end
	local lost = tiles_before - sim.o_tiles[B]
	expect(
		bad == 0 and in_all > 0,
		"every inner tile relinquished as fallout; ring tiles either fallout+unowned or untouched"
	)
	expect(
		ring_hit / ring > 0.4 and ring_hit / ring < 0.6,
		string.format("about half of the ring hit (%.2f)", ring_hit / ring)
	)
	expect(lost == in_all + ring_hit and sim.fallout_count == in_all + ring_hit, "lost tiles = fallout tiles")
	expect(#sim.d_flags == in_all + ring_hit and sim.d_flags[1] % 256 == 1, "flags delta entries tile*256+flags")
	local f = ((tiles_before - lost) / tiles_before) ^ 5
	expect(near(sim.o_troops[B], troops_before * f, 1e-6), "bomb troop loss x((T-n)/T)^5")
	expect(s_in.dead and not s_out.dead, "structures inside the outer radius destroyed")
	expect(F.has_msg(sim, "An Atom Bomb from Alpha hit your land", B), "hit message (cap_first a_an)")
	expect(sim:grudge_of(B, A), "grudge")
	expect(#sim.nukes == 0, "nuke list compacted")
end

-- =============================================================================================
print("hydrogen / warhead troop loss / alliance break")
do
	local sim, A, B, silo = setup(3)
	F.advance(sim, 100)
	sim:construction_tick()
	local C2 = F.owner(sim, "Charlie", Defs.KIND_HUMAN, 0, 50000)
	-- Charlie (A's ally) owns a strip near the hydrogen target
	F.claim(sim, C2, 760, 95, 6)
	sim:form_alliance(A, C2)
	local t = F.tile(760, 110)
	F.clear(sim)
	expect(sim:launch_nuke(A, "hydrogen", t), "hydrogen launch")
	local ae = F.events(sim, Ev.ALLY_END)
	expect(
		#ae == 1 and ae[1][4] == A and not sim:allied(A, C2),
		"allies with >= 100 weighted full-size tiles in the blast break with the launcher"
	)
	expect(
		F.has_msg(sim, "Alpha launched a Hydrogen Bomb at Bravo", C2),
		"non-atom launches are announced to other humans"
	)
	local n = sim.nukes[1]
	F.clear(sim)
	run_nukes_until(sim, function()
		return n.dead
	end, 500)
	local boom = F.events(sim, Ev.BOOM)[1]
	local _, outer = Rules.nuke_radii(Defs.N_HYDROGEN)
	expect(boom ~= nil and boom[5] == math.ceil(outer) and boom[5] == 100, "hydrogen BOOM radius 100")
	expect(
		F.has_msg(sim, "Hydrogen bomb detonated over Bravo", C2)
			and F.has_msg(sim, "Hydrogen bomb detonated over Bravo", A)
			and not F.has_msg(sim, "Hydrogen bomb detonated over Bravo", B),
		"hydrogen news to everyone but the victim"
	)
	-- warhead troop loss: 500 (1 - e^(-2 excess / max)) per full-size tile, floored at 3 % of max
	sim.o_troops[B] = 400000
	sim.o_cap[B] = 500000
	local tr = 400000
	for _ = 1, 3 do
		tr -= math.min(Rules.K_AREA * Rules.warhead_death(tr, 500000), math.max(0, tr - 15000))
	end
	sim:_nuke_troops(B, Defs.N_WARHEAD, 3, 1000)
	expect(near(sim.o_troops[B], tr, 1e-6), "warhead troop loss per tile")
	sim.o_troops[B] = 10000
	sim:_nuke_troops(B, Defs.N_WARHEAD, 50, 1000)
	expect(near(sim.o_troops[B], 10000), "no loss below 3 % of max troops")
end

-- =============================================================================================
print("a SAM under the arc shoots down a nuke passing over it")
do
	-- 2026-09-29: SAMs shoot down nukes that pass over them
	-- (the Sim flew a straight line under the drawn arc)
	-- a long shot (the arc bows by a third of the distance: it clears a SAM's range off the line)
	local sim, A, B, silo = setup(7)
	local t = F.tile(1000, 110)
	local arc = sim.R.nuke_arc(W, F.H, silo.tile, t)
	local zone = sim.R.NUKE_TARGETABLE_FULL / sim.R.K_LIN
	local r1 = sim.R.sam_range(1)
	local ax, ay = silo.tile % W + 0.5, silo.tile // W + 0.5
	local bx, by = t % W + 0.5, t // W + 0.5
	local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
	-- a point of the arc near the target (targetable) that the straight line passes farther than a
	-- level-1 SAM's range from
	local spot = -1
	for i = 99, 50, -1 do
		local x, y = sim.R.nuke_arc_at(arc, i / 100)
		local off = math.abs((bx - ax) * (ay - y) - (ax - x) * (by - ay)) / math.max(len, 1e-6)
		local tile = math.floor(y) * W + math.floor(x)
		if off > r1 * 1.1 and range_d2(t, tile) < (zone * 0.8) ^ 2 then
			spot = tile
			break
		end
	end
	expect(spot >= 0, "a point on the arc out of the straight line's reach")
	if spot >= 0 then
		local sam = sim:add_struct(Defs.S_SAM, B, spot)
		F.advance(sim, 300)
		sim:construction_tick()
		F.clear(sim)
		expect(sim:launch_nuke(A, "atom", t), "launch past the SAM")
		local n = sim.nukes[1]
		run_nukes_until(sim, function()
			return n.sam_sid ~= 0 or n.dead
		end, 800)
		expect(n.sam_sid == sam.sid, "the SAM under the arc intercepts it")
	end
end

-- =============================================================================================
print("stacked atom bombs (bulk launch)")
do
	local sim, A, B, silo = setup(8)
	sim:upgrade_struct(silo) -- level 2: two missile tubes
	F.advance(sim, 300)
	sim:construction_tick()
	local t = F.tile(760, 110)
	local g0 = sim.o_gold[A]
	sim:_apply_intent(A, { type = "nuke", kind = "atom", tile = t, amount = 5 })
	expect(#sim.nukes == 2, "amount 5 with two loaded missiles: two atom bombs")
	expect(near(g0 - sim.o_gold[A], 2 * Rules.nuke_cost("atom", 0)), "each bomb paid")
	sim:_apply_intent(A, { type = "nuke", kind = "hydrogen", tile = t, amount = 3 })
	expect(#sim.nukes == 2, "only atom bombs stack (no missile left anyway)")
end

-- =============================================================================================
print("SAM interception")
do
	local sim, A, B, silo = setup(4)
	local t = F.tile(760, 110)
	local sam = sim:add_struct(Defs.S_SAM, B, F.tile(770, 110))
	F.advance(sim, 300)
	sim:construction_tick()
	expect(silo.active and sam.active, "silo and SAM active")
	F.clear(sim)
	expect(sim:launch_nuke(A, "atom", t), "launch at a SAM-covered target")
	local n = sim.nukes[1]
	local fired = run_nukes_until(sim, function()
		return n.sam_sid ~= 0 or n.dead
	end, 500)
	local sl = F.events(sim, Ev.SAM_LAUNCH)
	expect(fired and #sl == 1 and n.sam_sid == sam.sid, "SAM fires")
	local e = sl[1]
	expect(
		e[2] == sam.sid and e[3] == n.uid and e[4] == sim.tick and e[5] == n.sam_hit_tick and e[6] == true,
		"SAM_LAUNCH sam_sid, nuke_uid, fire_tick, intercept_tick, true"
	)
	local k = n.sam_k
	local it = n.traj[k + 1]
	expect(
		#n.traj == n.flight + 1 and n.traj[1] == silo.tile and n.traj[#n.traj] == t,
		"trajectory: launch → target, one tile per tick"
	)
	-- the trajectory is the arc the renderer draws (Rules.nuke_arc), bowed toward the top of the map
	local on_arc = true
	for kk = 0, n.flight do
		local x, y = sim.R.nuke_arc_at(n.arc, kk / n.flight)
		if n.traj[kk + 1] ~= math.clamp(math.floor(y), 0, F.H - 1) * W + math.clamp(math.floor(x), 0, W - 1) then
			on_arc = false
		end
	end
	local mid = n.traj[n.flight // 2 + 1]
	expect(on_arc and mid // W < (silo.tile // W + t // W) / 2, "trajectory follows the arc (bowed toward the top)")
	local rr = Rules.sam_range_at(sam.level, n.launch_tick + k - sam.up_tick)
	expect(range_d2(sam.tile, it) <= rr * rr, "intercept point inside the SAM's range")
	local zone = Rules.NUKE_TARGETABLE_FULL / Rules.K_LIN
	expect(
		range_d2(t, it) < zone * zone or range_d2(silo.tile, it) < zone * zone or k == n.flight - 1,
		"intercept point targetable (near target or launch)"
	)
	local travel = math.ceil(geo_manhattan(sam.tile, it) * Rules.K_LIN / Rules.SAM_MISSILE_SPEED_FULL)
	expect(n.sam_hit_tick == e[4] + travel, "missile time = manhattan source / 12 per tick")
	expect(
		n.sam_hit_tick <= n.launch_tick + k and n.sam_hit_tick >= n.launch_tick + k - 1,
		"meets the bomb as it reaches the planned tile"
	)
	expect(n.sam_hit_tick < n.launch_tick + n.flight, "before detonation")
	expect(#sam.shots == 1 and sim:ready_missiles(sam, 90) == 0, "SAM missile reloading")
	F.clear(sim)
	local tiles0 = sim.o_tiles[B]
	run_nukes_until(sim, function()
		return n.dead
	end, 500)
	local boom = F.events(sim, Ev.BOOM)[1]
	expect(
		boom ~= nil and boom[5] == 0 and boom[4] == it and sim.tick == n.sam_hit_tick,
		"BOOM radius 0 at the intercept tile, at intercept_tick"
	)
	expect(sim.o_tiles[B] == tiles0 and sim.fallout_count == 0, "no blast")
	expect(
		F.has_msg(sim, "Your SAM shot down an Atom Bomb from Alpha", B)
			and F.has_msg(sim, "Your Atom Bomb was intercepted by Bravo", A),
		"interception messages"
	)
	expect(#sim:sam_rows() == 0, "sam_rows empty after the hit")

	-- SAM destroyed while its missile flies: the bomb flies on
	F.advance(sim, 90)
	expect(sim:launch_nuke(A, "atom", t), "second launch")
	local n2 = sim.nukes[1]
	run_nukes_until(sim, function()
		return n2.sam_sid ~= 0 or n2.dead
	end, 500)
	expect(n2.sam_sid == sam.sid and #sim:sam_rows() == 1, "SAM fired again (sam_rows)")
	sim:destroy_struct(sam)
	F.clear(sim)
	run_nukes_until(sim, function()
		return n2.dead
	end, 500)
	local b2 = F.events(sim, Ev.BOOM)[1]
	expect(b2 ~= nil and b2[5] > 0 and sim.tick == n2.launch_tick + n2.flight, "SAM lost: the bomb detonates on target")

	-- allied / own SAMs don't fire
	local sim2, A2, B2, silo2 = setup(5)
	local D2 = F.owner(sim2, "Delta", Defs.KIND_HUMAN, 0)
	F.claim(sim2, D2, 690, 125, 3)
	local sam2 = sim2:add_struct(Defs.S_SAM, D2, F.tile(690, 125))
	F.advance(sim2, 300)
	sim2:construction_tick()
	local C3 = F.owner(sim2, "Charlie", Defs.KIND_HUMAN, 0)
	F.claim(sim2, C3, 725, 125, 3)
	sim2:form_alliance(A2, D2)
	expect(sim2:launch_nuke(A2, "atom", F.tile(725, 125)) and sim2:allied(A2, D2), "launch near an allied SAM")
	local n3 = sim2.nukes[1]
	run_nukes_until(sim2, function()
		return n3.dead
	end, 500)
	expect(#F.events(sim2, Ev.SAM_LAUNCH) == 0 and #sam2.shots == 0, "allied SAM holds fire")
	local _ = silo2
end

-- =============================================================================================
print("MIRV")
do
	local sim, A, B, silo = setup(6)
	F.claim(sim, B, 800, 110, 40)
	F.advance(sim, 100)
	sim:construction_tick()
	local sam = sim:add_struct(Defs.S_SAM, B, F.tile(790, 110))
	F.advance(sim, 300)
	sim:construction_tick()
	local t = F.tile(800, 110)
	expect(
		Rules.nuke_cost("mirv", 0) == 25000000 and Rules.nuke_cost("mirv", 2) == 55000000,
		"MIRV cost 25M + 15M per MIRV launched"
	)
	local g0 = sim.o_gold[A]
	sim:form_alliance(A, B)
	sim:end_alliance(A, B, 0)
	F.clear(sim)
	expect(sim:launch_nuke(A, "mirv", t), "MIRV launch")
	expect(near(g0 - sim.o_gold[A], 25000000) and sim.mirvs_launched == 1, "MIRV charged 25M, mirvs_launched")
	local bus = sim.nukes[1]
	expect(
		bus.flight == sim.R.nuke_arc_ticks(sim.R.nuke_arc(W, F.H, silo.tile, t), Defs.N_MIRV),
		"MIRV flies its arc at 15 full-size tiles per tick"
	)
	local tb = sim.o_tiles[B]
	F.clear(sim)
	run_nukes_until(sim, function()
		return bus.dead
	end, 500)
	expect(bus.sam_sid == 0 and #sam.shots == 0, "the MIRV bus can't be intercepted")
	local boom = F.events(sim, Ev.BOOM)[1]
	expect(
		boom ~= nil and boom[2] == bus.uid and boom[3] == Defs.N_MIRV and boom[4] == t and boom[5] == -1,
		"BOOM radius -1 at the split"
	)
	local wh = F.events(sim, Ev.NUKE)
	expect(#wh >= 5 and #wh <= Rules.MIRV_WARHEADS, string.format("warheads spawned (%d)", #wh))
	local ok_owner, ok_spread, ok_gap, ok_from, ok_flight = true, true, true, true, true
	local gap = math.ceil(55 / Rules.K_LIN)
	for i, e in wh do
		local tt = e[6]
		if e[3] ~= Defs.N_WARHEAD or e[4] ~= A then
			ok_from = false
		end
		if e[5] ~= t then
			ok_from = false
		end
		if owned(sim, tt) ~= B then
			ok_owner = false
		end
		if range_d2(t, tt) > Rules.MIRV_SPREAD * Rules.MIRV_SPREAD then
			ok_spread = false
		end
		local base = sim.R.nuke_arc_ticks(sim.R.nuke_arc(W, F.H, t, tt), Defs.N_WARHEAD)
		if e[8] < math.max(base, 1) or e[8] > base + 15 then
			ok_flight = false
		end
		-- _mirv_overlaps compares warheads in the same or a neighbouring (gap x gap)-tile grid cell
		-- (no wrap), measured with geo_manhattan: no two warheads there are closer than `gap`.
		local gx, gy = (tt % W) // gap, (tt // W) // gap
		for j = 1, i - 1 do
			local o = wh[j][6]
			local ox, oy = (o % W) // gap, (o // W) // gap
			local ddx = math.abs(ox - gx)
			if math.abs(oy - gy) <= 1 and ddx <= 1 and geo_manhattan(o, tt) < gap then
				ok_gap = false
			end
		end
	end
	expect(wh[1][6] == t, "first warhead on the aim point")
	expect(ok_from, "warheads: kind N_WARHEAD, owner, from the split point")
	expect(ok_owner and ok_spread, "warheads land on the target's land within the spread")
	expect(ok_gap, "warheads >= 55 source (29) manhattan tiles apart within neighbouring grid cells (original rule)")
	expect(ok_flight, "warhead flight 22 full-size tiles per tick + 0..15 ticks")
	expect(sim.o_tiles[B] == tb, "the split itself destroys nothing")
	-- warheads are interceptable
	local fired = run_nukes_until(sim, function()
		return #F.events(sim, Ev.SAM_LAUNCH) > 0 or #sim.nukes == 0
	end, 800)
	local _ = fired
	local all = run_nukes_until(sim, function()
		return #sim.nukes == 0
	end, 800)
	local booms = F.events(sim, Ev.BOOM)
	local closed = {}
	for _, e in booms do
		closed[e[2]] = (closed[e[2]] or 0) + 1
	end
	local each_once = true
	for _, e in wh do
		if closed[e[2]] ~= 1 then
			each_once = false
		end
	end
	expect(all and each_once, "every warhead NUKE closed by exactly one BOOM")
	expect(sim.o_tiles[B] < tb and sim.fallout_count > 0, "warheads blast the target")
	local wboom = nil
	for _, e in booms do
		if e[3] == Defs.N_WARHEAD and e[5] > 0 then
			wboom = e
		end
	end
	local _, wo = Rules.nuke_radii(Defs.N_WARHEAD)
	expect(wboom ~= nil and wboom[5] == math.ceil(wo) and wboom[5] == 18, "warhead BOOM radius 18")
	-- MIRV at an ally breaks the alliance at the split
	local sim3, A3, B3, silo3 = setup(7)
	F.advance(sim3, 100)
	sim3:construction_tick()
	local C4 = F.owner(sim3, "Charlie", Defs.KIND_NATION, 0)
	F.claim(sim3, C4, 740, 125, 5)
	expect(sim3:launch_nuke(A3, "mirv", F.tile(740, 125)), "MIRV at Charlie")
	sim3:form_alliance(A3, C4)
	local n4 = sim3.nukes[1]
	F.clear(sim3)
	run_nukes_until(sim3, function()
		return n4.dead
	end, 500)
	expect(not sim3:allied(A3, C4) and #F.events(sim3, Ev.ALLY_END) == 1, "MIRV breaks an alliance with its target")
	local _ = B3
	local _2 = silo3
end

F.finish("simsys_nukes")
