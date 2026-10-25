-- The Arsenal's Sim rules (Core/SimArsenal + the Arsenal parts of SimNukes / SimStructures): unlock
-- gating, artillery, air strikes, the railgun, mega nukes, scattershot, reinforcements, rapid reload.
-- Run: .bin/lune run tests/arsenal.luau
local F = require("./simsys_fixture")
local Defs, Ev, Rules = F.Defs, F.Ev, F.Rules
local expect, near = F.expect, F.near

local range_d2 = F.map.range_d2
local STRUCT_KINDS = 16
local U = Defs.UNLOCK

local function owned(sim, t)
	return buffer.readi32(sim.owner, t * 4)
end

--- Runs the Arsenal and nuke ticks until `cond` (or `max_ticks`).
local function run_until(sim, cond, max_ticks)
	for _ = 1, max_ticks or 1000 do
		F.advance(sim, 1)
		sim:construction_tick()
		sim:arsenal_tick()
		sim:nukes_tick()
		if cond() then
			return true
		end
	end
	return false
end

local function finish_building(sim)
	F.advance(sim, 400)
	sim:construction_tick()
end

-- A in Kazakhstan, B right next to it (their lands touch), both rich.
local function setup(seed)
	local sim = F.new_sim(seed)
	local A = F.owner(sim, "Alpha", Defs.KIND_HUMAN, 100000000, 100000)
	local B = F.owner(sim, "Bravo", Defs.KIND_HUMAN, 100000000, 400000)
	F.claim(sim, A, 690, 100, 12)
	F.claim(sim, B, 716, 100, 14)
	sim.o_cap[A] = 500000
	sim.o_cap[B] = 1000000
	return sim, A, B
end

-- =============================================================================================
print("unlocks gate every Arsenal item")
do
	local sim, A, B = setup(1)
	local own = F.tile(690, 100)
	local enemy = F.tile(716, 100)
	F.clear(sim)
	local ok = sim:try_build(A, "artillery", own)
	expect(not ok and F.has_msg(sim, "Unlock Artillery in the Arsenal first", A), "artillery is locked")
	expect(not sim:try_build(A, "airfield", own) and not sim:try_build(A, "railgun", own), "airfield, railgun locked")
	expect(sim.n_structs == 0 and sim.o_gold[A] == 100000000, "nothing built, nothing charged")
	local silo = sim:add_struct(Defs.S_SILO, A, own)
	finish_building(sim)
	F.clear(sim)
	expect(
		not sim:launch_nuke(A, "mega", enemy) and F.has_msg(sim, "Unlock the Mega Nuke in the Arsenal first", A),
		"mega nuke is locked"
	)
	expect(not sim:launch_nuke(A, "scatter", enemy), "scattershot is locked")
	expect(not sim:launch_nuke(A, "airstrike", enemy) and not sim:launch_nuke(A, "slug", enemy), "strikes locked")
	expect(not sim:launch_nuke(A, "shell", enemy), "a shell is never launched by hand")
	expect(#silo.shots == 0 and #sim.nukes == 0, "no missile left the silo")
	F.clear(sim)
	expect(
		not sim:reinforce(A) and F.has_msg(sim, "Unlock Reinforcements in the Arsenal first", A),
		"reinforcements locked"
	)
	expect(sim:launch_nuke(A, "atom", enemy), "an atom bomb needs no unlock")
	sim:set_unlocks(A, U.mega)
	expect(sim:has_unlock(A, U.mega) and not sim:has_unlock(A, U.scatter), "set_unlocks: one bit")
	sim:set_unlocks(A, 99999)
	expect(sim.o_unlock[A] == bit32.band(99999, Defs.UNLOCK_ALL), "set_unlocks keeps known bits only")
	sim:set_unlocks(B, 0 / 0)
	expect(sim.o_unlock[B] == 0, "set_unlocks ignores NaN")
end

-- =============================================================================================
print("artillery")
do
	local sim, A, B = setup(2)
	sim:set_unlocks(A, U.artillery)
	local site = F.tile(698, 100)
	expect(Rules.build_cost("artillery", 0) == 150000 and Rules.build_cost("artillery", 9) == 750000, "price ladder")
	local ok = sim:try_build(A, "artillery", site)
	expect(ok and sim.o_gold[A] == 100000000 - 150000, "built for 150,000")
	local bat = sim.struct_list[1]
	expect(bat.kind == Defs.S_ARTILLERY and not bat.active, "under construction")
	local _, up = sim:try_build(A, "artillery", site)
	expect(up ~= true and sim.struct_list[1].level == 1, "not upgradable")
	F.advance(sim, Rules.BUILD_TICKS[Defs.S_ARTILLERY])
	sim:construction_tick()
	expect(bat.active and #sim.batteries == 1, "active after 8 s")
	expect(
		bat.next_fire >= sim.tick + Rules.ARTILLERY_GAP_MIN and bat.next_fire <= sim.tick + Rules.ARTILLERY_GAP_MAX,
		"waits one gap before its first shot"
	)
	-- an enemy city in range is the first thing it shells
	local city_tile = F.tile(712, 100)
	local city = sim:add_struct(Defs.S_CITY, B, city_tile)
	finish_building(sim)
	expect(range_d2(bat.tile, city_tile) <= Rules.artillery_range() ^ 2, "(the city is in range)")
	F.clear(sim)
	local fired = run_until(sim, function()
		return #sim.nukes > 0
	end, 100)
	local shell = sim.nukes[1]
	expect(fired and shell.kind == Defs.N_SHELL and shell.owner == A, "fires a shell")
	expect(shell.from_tile == bat.tile and shell.to_tile == city_tile, "at the nearest enemy structure")
	local ev = F.events(sim, Ev.NUKE)
	expect(#ev == 1 and ev[1][3] == Defs.N_SHELL, "announced as a NUKE event of kind shell")
	local d = math.sqrt(range_d2(bat.tile, city_tile))
	expect(shell.flight == math.max(1, math.ceil(d / Rules.NUKE_SPEED_FULL[Defs.N_SHELL])), "6 tiles per tick, straight")
	expect(#F.msgs(sim, B) == 0, "no alert for a shell")
	-- the hit: 2.88 % of the army whose land it hits, 150 damage to the city
	local before = sim.o_troops[B]
	local tiles_before = sim.o_tiles[B]
	F.clear(sim)
	run_until(sim, function()
		return #F.events(sim, Ev.BOOM) > 0
	end, 60)
	expect(near(before - sim.o_troops[B], math.floor(before * Rules.SHELL_KILL_FRAC)), "kills 2.88 % of the army")
	expect(sim.o_tiles[B] == tiles_before and owned(sim, city_tile) == B, "takes no land")
	expect(sim.fallout_count == 0, "leaves no fallout")
	expect(city.hp == Rules.STRUCT_HP[Defs.S_CITY] - 150 and not city.dead, "150 damage to the city")
	local boom = F.events(sim, Ev.BOOM)[1]
	expect(boom[3] == Defs.N_SHELL and boom[4] == city_tile and boom[5] >= 1, "BOOM with a radius")
	-- seven shells level a city
	local shells = 1
	run_until(sim, function()
		shells += #F.events(sim, Ev.BOOM)
		F.clear(sim)
		return city.dead
	end, 2000)
	expect(city.dead, "the city falls to shelling")
	-- kill clamps
	expect(Rules.strike_kill(Defs.N_SHELL, 20000, 1) == 1440, "a small army loses at least 1,440")
	expect(Rules.strike_kill(Defs.N_SHELL, 900, 1) == 900, "never more than the army")
	expect(Rules.strike_kill(Defs.N_SHELL, 5000000, 1) == 19200, "at most 19,200")
	-- allies and its own land are left alone
	sim:form_alliance(A, B)
	for _, n in sim.nukes do
		n.dead = true
	end
	F.clear(sim)
	local quiet = not run_until(sim, function()
		return #F.events(sim, Ev.NUKE) > 0
	end, 300)
	expect(quiet, "never shells an ally")
	sim:end_alliance(A, B, 0)
	-- captured ground: the battery is destroyed, not handed over
	F.clear(sim)
	sim:set_owner(bat.tile, B)
	expect(bat.dead and #F.events(sim, Ev.STRUCT_OWNER) == 0, "destroyed when its tile is captured")
	sim:arsenal_tick()
	expect(#sim.batteries == 0, "and leaves the battery list")
end

-- =============================================================================================
print("air strike")
do
	local sim, A, B = setup(3)
	sim:set_unlocks(A, U.airfield)
	local site = F.tile(690, 100)
	local ok = sim:try_build(A, "airfield", site)
	expect(ok and sim.o_gold[A] == 100000000 - 500000, "an airfield for 500,000")
	local field = sim.struct_list[1]
	local target = F.tile(716, 100)
	F.clear(sim)
	expect(
		not sim:launch_nuke(A, "airstrike", target) and F.has_msg(sim, "No airfield is ready", A),
		"not while it is being built"
	)
	finish_building(sim)
	local far = F.tile(900, 100)
	sim:set_owner(far, B)
	F.clear(sim)
	expect(
		not sim:launch_nuke(A, "airstrike", far) and F.has_msg(sim, "That is out of your airfield's reach", A),
		"out of reach beyond 156 tiles"
	)
	F.clear(sim)
	expect(
		not sim:launch_nuke(A, "airstrike", site) and F.has_msg(sim, "You can't strike your own land", A),
		"not on your own land"
	)
	local city = sim:add_struct(Defs.S_CITY, B, target)
	local post = sim:add_struct(Defs.S_DEFENSE, B, F.tile(716, 106))
	finish_building(sim)
	sim:upgrade_struct(city)
	local gold = sim.o_gold[A]
	F.clear(sim)
	expect(sim:launch_nuke(A, "airstrike", target) and sim.o_gold[A] == gold, "the strike is free")
	local n = sim.nukes[1]
	expect(n.kind == Defs.N_AIRSTRIKE and n.from_tile == site, "leaves the airfield")
	expect(#field.shots == 1 and #F.events(sim, Ev.STRUCT_SHOTS) == 1, "the airfield rearms (STRUCT_SHOTS)")
	expect(not sim:launch_nuke(A, "airstrike", target), "one sortie per rearm")
	local before = sim.o_troops[B]
	local tiles_before = sim.o_tiles[B]
	run_until(sim, function()
		return #sim.nukes == 0
	end, 200)
	local disc = 0
	local r = Rules.NUKE_OUTER_FULL[Defs.N_AIRSTRIKE]
	for _, t in sim:disk_tiles(target, r, true) do
		if owned(sim, t) == B then
			disc += 1
		end
	end
	local want = math.floor(math.min(before, disc * 60, before * 0.06))
	expect(near(before - sim.o_troops[B], want) and want > 0, "kills 60 per tile hit, up to 6 % of the army")
	expect(sim.o_tiles[B] == tiles_before and sim.fallout_count == 0, "takes no land, leaves no fallout")
	expect(city.level == 2 and city.hp == 400, "600 damage to a city")
	expect(post.dead, "a defense post (600) is destroyed")
	expect(F.has_msg(sim, "An Air Strike from Alpha hit your land", B), "the victim is told")
	-- a second strike takes a level off the city
	F.advance(sim, Rules.RELOAD_TICKS[Defs.S_AIRFIELD])
	F.clear(sim)
	expect(sim:launch_nuke(A, "airstrike", target), "rearmed after 30 s")
	run_until(sim, function()
		return #sim.nukes == 0
	end, 200)
	local lv = F.events(sim, Ev.STRUCT_LEVEL)
	expect(city.level == 1 and city.hp == 1000 and not city.dead, "the city loses a level and is whole again")
	expect(#lv == 1 and lv[1][2] == city.sid and lv[1][3] == 1, "STRUCT_LEVEL announces it")
	expect(
		sim.o_slevel[B * STRUCT_KINDS + Defs.S_CITY] == 1 and sim.o_alevel[B * STRUCT_KINDS + Defs.S_CITY] == 1,
		"level counts follow"
	)
	expect(sim.o_built[B * STRUCT_KINDS + Defs.S_CITY] == 2, "what was built is remembered (the next city's price)")
	-- no SAM stops it
	local sam = sim:add_struct(Defs.S_SAM, B, F.tile(716, 94))
	finish_building(sim)
	F.clear(sim)
	sim:launch_nuke(A, "airstrike", target)
	run_until(sim, function()
		return #sim.nukes == 0
	end, 200)
	expect(#F.events(sim, Ev.SAM_LAUNCH) == 0 and #sam.shots == 0, "SAMs don't fire at an air strike")
end

-- =============================================================================================
print("railgun")
do
	local sim, A, B = setup(4)
	sim:set_unlocks(A, U.railgun)
	expect(Rules.build_cost("railgun", 0) == 2500000 and Rules.build_cost("railgun", 5) == 7500000, "price ladder")
	sim:try_build(A, "railgun", F.tile(690, 100))
	local gun = sim.struct_list[1]
	finish_building(sim)
	-- anywhere on the map
	local far = F.claim(sim, B, 540, 110, 6) -- (central Europe)
	local silo = sim:add_struct(Defs.S_SILO, B, far)
	finish_building(sim)
	sim:upgrade_struct(silo)
	sim:upgrade_struct(silo)
	expect(silo.level == 3 and #silo.shots == 2, "(a level 3 silo, two missiles reloading)")
	F.clear(sim)
	expect(sim:launch_nuke(A, "slug", far), "fires at a tile across the map")
	local n = sim.nukes[1]
	expect(n.kind == Defs.N_SLUG and n.flight <= 30, "the slug is there in under 3 s")
	local before = sim.o_troops[B]
	run_until(sim, function()
		return #sim.nukes == 0
	end, 100)
	expect(silo.level == 2 and #silo.shots == 2, "one shot takes a level off a silo")
	expect(before - sim.o_troops[B] > 0 and before - sim.o_troops[B] <= before * 0.04 + 1, "at most 4 % of the army")
	expect(not sim:launch_nuke(A, "slug", far), "reloading")
	F.advance(sim, Rules.RELOAD_TICKS[Defs.S_RAILGUN])
	sim:launch_nuke(A, "slug", far)
	run_until(sim, function()
		return #sim.nukes == 0
	end, 100)
	expect(silo.level == 1 and #silo.shots == 1, "a lost slot takes a reloading missile with it")
	F.advance(sim, Rules.RELOAD_TICKS[Defs.S_RAILGUN])
	F.clear(sim)
	sim:launch_nuke(A, "slug", far)
	run_until(sim, function()
		return #sim.nukes == 0
	end, 100)
	expect(silo.dead and F.has_msg(sim, "Alpha destroyed your Missile Silo", B), "at level 1 it is destroyed")
	expect(not gun.dead, "(the gun stands)")
end

-- =============================================================================================
print("mega nuke")
do
	local sim, A, B = setup(5)
	sim:set_unlocks(A, U.mega)
	sim:add_struct(Defs.S_SILO, A, F.tile(690, 100))
	finish_building(sim)
	local inner, outer = Rules.nuke_radii(Defs.N_MEGA)
	local ai, ao = Rules.nuke_radii(Defs.N_ATOM)
	expect(inner == 2 * ai and outer == 2 * ao, "twice an atom bomb's radii")
	expect(Rules.nuke_cost("mega") == 2500000, "2,500,000 gold")
	local target = F.claim(sim, B, 800, 100, 40)
	local gold = sim.o_gold[A]
	F.clear(sim)
	expect(sim:launch_nuke(A, "mega", target) and sim.o_gold[A] == gold - 2500000, "launches from a silo")
	expect(F.has_msg(sim, "Alpha launched a Mega Nuke at you!", B), "the target is warned")
	run_until(sim, function()
		return #sim.nukes == 0
	end, 600)
	expect(owned(sim, target) == 0 and sim.fallout_count > 4000, "a crater four times an atom bomb's")
	local wiped = true
	for _, t in sim:disk_tiles(target, inner, true) do
		if owned(sim, t) ~= 0 then
			wiped = false
		end
	end
	expect(wiped, "nothing is left inside the inner radius")
	-- a SAM stops it
	local sim2, A2, B2 = setup(6)
	sim2:set_unlocks(A2, U.mega)
	sim2:add_struct(Defs.S_SILO, A2, F.tile(690, 100))
	local t2 = F.claim(sim2, B2, 760, 100, 20)
	sim2:add_struct(Defs.S_SAM, B2, t2)
	finish_building(sim2)
	F.clear(sim2)
	sim2:launch_nuke(A2, "mega", t2)
	run_until(sim2, function()
		return #sim2.nukes == 0
	end, 600)
	expect(owned(sim2, t2) == B2 and sim2.fallout_count == 0, "a SAM shoots it down")
end

-- =============================================================================================
print("scattershot")
do
	local sim, A, B = setup(7)
	sim:set_unlocks(A, U.scatter)
	local silo_tile = F.tile(690, 100)
	sim:add_struct(Defs.S_SILO, A, silo_tile)
	finish_building(sim)
	local target = F.claim(sim, B, 800, 100, 45)
	F.clear(sim)
	local gold = sim.o_gold[A]
	expect(sim:launch_nuke(A, "scatter", target) and sim.o_gold[A] == gold - 3750000, "3,750,000 gold")
	local warheads = 0
	local ok_ring = true
	for _, n in sim.nukes do
		if n.kind == Defs.N_WARHEAD then
			warheads += 1
			local d = math.sqrt(range_d2(target, n.to_tile))
			if d < Rules.SCATTER_NEAR_FULL - 1.5 or d > Rules.SCATTER_FAR_FULL + 1.5 or n.from_tile ~= silo_tile then
				ok_ring = false
			end
			if owned(sim, n.to_tile) == A then
				ok_ring = false
			end
		end
	end
	expect(sim.nukes[1].kind == Defs.N_SCATTER and #sim.nukes == warheads + 1, "one bomb and its warheads")
	expect(warheads >= Rules.SCATTER_MIN and warheads <= Rules.SCATTER_MAX, "4 to 6 warheads")
	expect(ok_ring, "28 to 46 tiles around the aim point, from the same silo")
	expect(#F.events(sim, Ev.NUKE) == warheads + 1, "each is announced")
	local main = sim.nukes[1]
	local late = true
	for _, n in sim.nukes do
		if n.kind == Defs.N_WARHEAD and n.flight <= main.flight then
			late = false
		end
	end
	expect(late, "the warheads land after the bomb, one after another")
	run_until(sim, function()
		return #sim.nukes == 0
	end, 800)
	expect(owned(sim, target) == 0, "the bomb's own crater")
	expect(sim.fallout_count > 2800, "more ground than one atom bomb")
	-- never onto the shooter's land
	local sim2, A2, B2 = setup(8)
	sim2:set_unlocks(A2, U.scatter)
	sim2:add_struct(Defs.S_SILO, A2, F.tile(690, 100))
	finish_building(sim2)
	local edge = F.tile(704, 100) -- B's land right at A's border
	sim2:set_owner(edge, B2)
	sim2:launch_nuke(A2, "scatter", edge)
	local own_hit = false
	for _, n in sim2.nukes do
		if n.kind == Defs.N_WARHEAD and owned(sim2, n.to_tile) == A2 then
			own_hit = true
		end
	end
	expect(not own_hit, "no warhead is aimed at the shooter's own land")
end

-- =============================================================================================
print("reinforcements")
do
	local sim, A = setup(9)
	sim:set_unlocks(A, U.reinforce)
	sim.o_troops[A] = 100000
	sim.o_cap[A] = 500000
	F.clear(sim)
	local gold = sim.o_gold[A]
	expect(sim:reinforce(A), "called")
	expect(sim.o_troops[A] == 200000 and sim.o_gold[A] == gold - 100000, "a fifth of the cap for 100,000 gold")
	local ev = F.events(sim, Ev.REINFORCE)
	expect(
		#ev == 1 and ev[1][2] == A and ev[1][3] == 100000 and ev[1][4] == sim.tick + Rules.REINFORCE_COOLDOWN_TICKS,
		"REINFORCE event with the troops and when the next is ready"
	)
	F.clear(sim)
	expect(not sim:reinforce(A) and F.has_msg(sim, "Reinforcements are ready in 30 s", A), "30 s between calls")
	expect(sim:reinforce_wait(A) == 300, "reinforce_wait")
	F.advance(sim, 300)
	sim.o_troops[A] = 450000
	expect(sim:reinforce(A) and sim.o_troops[A] == 500000, "never past the cap")
	F.advance(sim, 300)
	F.clear(sim)
	expect(
		not sim:reinforce(A) and F.has_msg(sim, "Your army is already at its cap", A) and sim.o_gold[A] == gold - 200000,
		"nothing to bring at the cap (and no charge)"
	)
	sim.o_troops[A] = 1000
	sim.o_gold[A] = 500
	F.clear(sim)
	expect(not sim:reinforce(A) and F.has_msg(sim, "Not enough gold for Reinforcements", A), "needs the gold")
	sim.o_gold[A] = 1000000
	sim:_apply_intent(A, { type = "reinforce" })
	expect(sim.o_troops[A] == 101000, "the reinforce intent")
end

-- =============================================================================================
print("rapid reload")
do
	local sim, A, B = setup(10)
	sim:set_unlocks(A, U.reload2x)
	local silo = sim:add_struct(Defs.S_SILO, A, F.tile(690, 100))
	finish_building(sim)
	local target = F.tile(716, 100)
	expect(sim:launch_nuke(A, "atom", target), "(an atom bomb)")
	expect(silo.shots[1] == sim.tick - 45, "the shot is recorded 45 ticks early")
	F.advance(sim, 44)
	expect(sim:ready_missiles(silo, Rules.SILO_COOLDOWN_TICKS) == 0, "still reloading after 4.4 s")
	F.advance(sim, 1)
	expect(sim:ready_missiles(silo, Rules.SILO_COOLDOWN_TICKS) == 1, "loaded again after 4.5 s (half of 9)")
	-- B without it: the full 9 s
	local silo_b = sim:add_struct(Defs.S_SILO, B, F.tile(716, 100))
	finish_building(sim)
	sim:launch_nuke(B, "atom", F.tile(690, 100))
	expect(silo_b.shots[1] == sim.tick, "without it a shot is recorded as fired now")
	-- batteries fire twice as often
	sim:set_unlocks(A, U.reload2x + U.artillery)
	local slow, fast = 0, 0
	local bat = sim:add_struct(Defs.S_ARTILLERY, A, F.tile(698, 106))
	for _ = 1, 400 do
		fast += sim:_battery_gap(bat)
	end
	sim:set_unlocks(A, U.artillery)
	for _ = 1, 400 do
		slow += sim:_battery_gap(bat)
	end
	expect(fast < slow * 0.56 and fast > slow * 0.44, "a battery's gap is halved")
end

-- =============================================================================================
print("a takeover keeps the commander's Arsenal")
do
	local sim, A = setup(11)
	local N = F.owner(sim, "Nation", Defs.KIND_NATION, 0, 50000)
	F.claim(sim, N, 760, 130, 6)
	sim.o_ai[N] = 1
	sim:set_unlocks(A, U.mega + U.artillery)
	for _, t in sim:disk_tiles(F.tile(690, 100), 60, true) do
		if owned(sim, t) == A then
			sim:set_owner(t, 0)
		end
	end
	sim.o_alive[A] = 0
	expect(sim:take_over(A, N), "(took over)")
	expect(sim.o_unlock[N] == U.mega + U.artillery, "the nation plays with its new commander's unlocks")
end

-- =============================================================================================
print("flight paths")
do
	local R = Rules
	local a, b = F.tile(690, 100), F.tile(760, 100)
	local flat = R.munition_arc(F.W, F.H, a, b, Defs.N_SLUG)
	local x, y = R.nuke_arc_at(flat, 0.5)
	expect(near(y, a // F.W + 0.5, 1e-6) and near(x, (a % F.W + b % F.W) / 2 + 0.5, 1e-6), "a slug flies straight")
	local arc = R.munition_arc(F.W, F.H, a, b, Defs.N_MEGA)
	local _, ay = R.nuke_arc_at(arc, 0.5)
	expect(ay < a // F.W - 10, "a mega nuke flies the bombs' arc")
	expect(R.launch_range(Defs.N_AIRSTRIKE) == 156 and R.launch_range(Defs.N_SLUG) == 0, "reach")
	expect(Defs.nuke_kind_from_name("slug") == Defs.N_SLUG and Defs.struct_kind_from_name("railgun") == 8, "names")
end

F.finish("arsenal")
