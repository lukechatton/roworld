-- sim-systems: SimAI / SimAIEconomy tests (per-AI parameters, build choice ratios and perceived
-- cost, crowded upgrades, human protection, warship retaliation, alliance acceptance, attack
-- cadence by difficulty in a real match). Run: .bin/lune run tests/simsys_ai.luau
local F = require("./simsys_fixture")
local Defs, Rules = F.Defs, F.Rules
local expect, near = F.expect, F.near
local SimAI = require("../src/shared/Core/SimAI")
local WorldMap = require("../src/shared/Core/WorldMap")

-- =============================================================================================
print("setup: per-AI ratios")
do
	local sim = F.new_sim(1)
	local ai = SimAI.new()
	ai:setup(sim)
	local ok = true
	for id = 1, Defs.MAX_OWNERS - 1 do
		local tr, rr, er = ai.trigger_r[id], ai.reserve_r[id], ai.expand_r[id]
		-- nextInt(50, 60) / 100 etc.: nextInt excludes its upper bound.
		if
			tr < 0.5 - 1e-9
			or tr > 0.59 + 1e-9
			or rr < 0.3 - 1e-9
			or rr > 0.39 + 1e-9
			or er < 0.1 - 1e-9
			or er > 0.19 + 1e-9
		then
			ok = false
		end
		for _, r in { tr, rr, er } do
			if r ~= math.floor(r * 100 + 0.5) / 100 then
				ok = false
			end
		end
		if
			ai.aggression[id] < 0.8 - 1e-6
			or ai.aggression[id] > 1.25 + 1e-6
			or ai.naval[id] < 0.5 - 1e-6
			or ai.naval[id] > 1.5 + 1e-6
		then
			ok = false
		end
		if
			ai.grace_jitter[id] < 0
			or ai.grace_jitter[id] > Rules.HUMAN_GRACE_JITTER
			or ai.last_ally_ask[id] < 0
			or ai.last_ally_ask[id] > 600
		then
			ok = false
		end
		if ai.next_think[id] ~= id % 15 or ai.last_nuke[id] ~= -100000 or ai.rank[id] ~= 999 then
			ok = false
		end
	end
	expect(
		ok,
		"trigger 0.50-0.59, reserve 0.30-0.39, expand 0.10-0.19 (hundredths), aggression, naval, jitter, staggered think"
	)
	expect(
		ai.last_defense[5] == -100000
			and ai.last_retint[5] == -100000
			and ai._lab_col[5] == -1
			and ai.attackers_on[0] == 0,
		"economy arrays filled"
	)
	expect(
		SimAI.NUKE_AGE[1] == 3600 and SimAI.SAM_PER_CITY[2] == Defs.f32(0.25) and SimAI.WARSHIP_FLEET_CAP == 10,
		"base constants visible on SimAI"
	)
	expect(
		SimAI._above({ o_troops = { [3] = 1000 }, o_cap = { [3] = 2000 } }, 3, 0.3) == 0.4,
		"_above = (troops - keep*cap) / troops"
	)
	expect(
		SimAI._great_powers(0.12, 0.08) and SimAI._great_powers(0.08, 0.13) and not SimAI._great_powers(0.11, 0.11),
		"_great_powers"
	)
end

-- =============================================================================================
print("build choice (NationStructureBehavior ratios, perceived cost, upgrades)")
do
	-- A nation on the Spanish coast; try_build is intercepted to record the decision.
	local sim = F.new_sim(2)
	sim.difficulty = 1
	local N1 = F.owner(sim, "Nation", Defs.KIND_NATION, 100000000, 100000)
	F.claim(sim, N1, 495, 142, 13) -- (13: over 1500 land tiles on the World map made from Natural Earth)
	local ai = SimAI.new()
	ai:setup(sim)
	local picked = nil
	-- every kind handed to site selection, in order; `site_of[kind name]` gives one a site
	local tried = {}
	local site_of = {}
	local built = nil
	sim.try_build = function(_self, id, kind_name, t)
		built = kind_name
		return true
	end
	-- record the first kind handed to site selection (the counts below are synthetic, so there are
	-- no real hub structures to place next to). With no site the AI goes on down its build order.
	ai._pick_site = function(_self, _sim, _id, kind, _threat)
		local name = Defs.STRUCT_NAMES[kind]
		table.insert(tried, name)
		if picked == nil then
			picked = name
		end
		return site_of[name] or -1
	end
	local real_tiles = sim.o_tiles[N1]
	sim.o_tiles[N1] = 100000 -- not crowded: no upgrade branch
	local function decide(counts, age, gold)
		for k = 0, 7 do
			sim.o_scount[N1 * 16 + k] = counts[k] or 0
			sim.o_slevel[N1 * 16 + k] = counts[k] or 0
			sim.o_built[N1 * 16 + k] = counts[k] or 0
		end
		sim.o_gold[N1] = gold or 100000000
		sim.tick = 100000
		sim.playing_since = sim.tick - (age or 3000)
		ai.last_build[N1] = -1000
		ai.rank[N1] = 1
		picked = nil
		built = nil
		table.clear(tried)
		sim:scan_border(N1, 400)
		ai:_consider_build(sim, N1, age or 3000)
		return picked
	end
	local S = Defs
	expect(sim.o_coast[N1] > 0, "coastal nation")
	expect(decide({}) == "port", "a nation with a coast: first a port (PORT_FIRST)")
	ai.crowded_first[N1] = 1
	expect(decide({}) == "city", "then cities")
	expect(decide({ [S.S_CITY] = 4 }) == "port", "coastal: ports while < 0.75 x cities")
	expect(
		decide({ [S.S_CITY] = 4, [S.S_PORT] = 3 }) == "silo",
		"4 cities: factories < int(4*0.75*0.33)=0 → next rule (silo 0 < int(1.6))"
	)
	expect(
		decide({ [S.S_CITY] = 10, [S.S_PORT] = 7 }) == "factory",
		"factories < int(10 x 0.75 x 0.33) = 2 with a coast"
	)
	expect(
		decide({ [S.S_CITY] = 10, [S.S_PORT] = 7, [S.S_FACTORY] = 2 }, 3000) == "sam",
		"SAMs < int(10 x 0.2) after the land grab (Standard)"
	)
	expect(
		decide({ [S.S_CITY] = 10, [S.S_PORT] = 7, [S.S_FACTORY] = 2 }, 1000) ~= "sam",
		"no SAMs before NATION_WAR_AGE"
	)
	expect(
		decide({ [S.S_CITY] = 10, [S.S_PORT] = 7, [S.S_FACTORY] = 2, [S.S_SAM] = 2 }, 3000) == "silo",
		"first silo < int(10 x 0.4) after NUKE_AGE - 900"
	)
	expect(
		decide({ [S.S_CITY] = 10, [S.S_PORT] = 7, [S.S_FACTORY] = 2, [S.S_SAM] = 2 }, 2600) == "city",
		"no silo before NUKE_AGE - 900 (2700 on Standard)"
	)
	ai.rank[N1] = 13
	local function decide_rank(counts, age, rank)
		for k = 0, 7 do
			sim.o_scount[N1 * 16 + k] = counts[k] or 0
			sim.o_slevel[N1 * 16 + k] = counts[k] or 0
			sim.o_built[N1 * 16 + k] = counts[k] or 0
		end
		sim.o_gold[N1] = 100000000
		sim.playing_since = sim.tick - age
		ai.last_build[N1] = -1000
		ai.rank[N1] = rank
		picked = nil
		built = nil
		table.clear(tried)
		ai:_consider_build(sim, N1, age)
		return picked
	end
	expect(
		decide_rank({ [S.S_CITY] = 10, [S.S_PORT] = 7, [S.S_FACTORY] = 2, [S.S_SAM] = 2 }, 3000, 13) == "city",
		"only the 12 largest nations build silos"
	)
	expect(
		decide_rank({ [S.S_CITY] = 10, [S.S_PORT] = 7, [S.S_FACTORY] = 2, [S.S_SAM] = 2, [S.S_SILO] = 1 }, 3000, 1)
			== "silo",
		"then silos < int(10 x 0.2)"
	)
	expect(
		decide_rank({ [S.S_CITY] = 20, [S.S_PORT] = 15, [S.S_FACTORY] = 4, [S.S_SAM] = 4, [S.S_SILO] = 3 }, 3000, 1)
			== "city",
		"at most 3 silos"
	)
	-- perceived cost: gold below MIRV + hydrogen, each owned structure adds its price, from the
	-- third city on (CITIES_BEFORE_SAVING)
	expect(
		decide({ [S.S_CITY] = 1 }, 3000, 130000) == nil and decide({}, 3000, 130000) == "city",
		"a second city costs 250K"
	)
	expect(
		decide({ [S.S_CITY] = 2, [S.S_PORT] = 1 }, 1000, Rules.build_cost("city", 2)) == "city",
		"no saving up before the third city: the third at its real price"
	)
	expect(
		decide({ [S.S_CITY] = 3, [S.S_PORT] = 2 }, 1000, Rules.build_cost("city", 3) * 3.9) == nil
			and decide({ [S.S_CITY] = 3, [S.S_PORT] = 2 }, 1000, Rules.build_cost("city", 3) * 4) == "city",
		"from the third city on a city is perceived at x(1 + cities)"
	)
	-- the build order falls through: what can't be afforded or placed gives way to the next
	expect(
		decide({ [S.S_CITY] = 4 }) == "port" and table.concat(tried, ",") == "port,silo,city",
		"no site for the port: the silo that is due, then a city, are tried"
	)
	site_of.city = F.tile(495, 142)
	expect(
		decide({ [S.S_CITY] = 4 }, 1000) == "port" and built == "city" and ai.last_build[N1] == sim.tick,
		"no site for the port: a city is built instead"
	)
	site_of.city = nil
	expect(
		decide({ [S.S_CITY] = 2 }, 1000, Rules.build_cost("port", 0)) == "port",
		"a port (125K) while the next city (500K) is out of reach"
	)
	-- a crowded map (more than a nation per 7,500 land tiles): the first structure is a port
	expect(ai:_crowded_map(sim) == false, "the fixture's few nations are not a crowded map")
	ai.crowded_first[N1] = 0
	site_of.port = F.tile(495, 142)
	expect(
		decide({}) == "port" and built == "port" and ai.crowded_first[N1] == 1,
		"the first structure is a port"
	)
	expect(decide({}) == "city", "once only, then cities as ever")
	site_of.port = nil
	ai.crowded_first[N1] = 0
	expect(
		decide({}) == "port" and table.concat(tried, ",") == "port,city" and ai.crowded_first[N1] == 1,
		"no site for it: a city, and cities from then on"
	)
	ai.crowded_first[N1] = 0
	expect(
		decide({}, 3000, 120000) == nil and ai.crowded_first[N1] == 0,
		"a port first is waited for (125K), not skipped for want of gold"
	)
	ai._crowded = false
	local cost_port = Rules.build_cost("port", 0)
	expect(decide({ [S.S_CITY] = 4, [S.S_PORT] = 1 }, 3000, cost_port * 1.9) == nil, "port perceived at x(1+1)")
	expect(decide({}, 3000, 99999) == nil, "nothing below 100K gold")
	-- crowded territory: upgrade an existing finished structure instead
	sim.try_build = nil
	ai._pick_site = nil
	ai.crowded_first[N1] = 1 -- (its first structure stands)
	sim.o_tiles[N1] = real_tiles
	for k = 0, 7 do
		sim.o_scount[N1 * 16 + k] = 0
		sim.o_slevel[N1 * 16 + k] = 0
		sim.o_built[N1 * 16 + k] = 0
	end
	local c1 = sim:add_struct(Defs.S_CITY, N1, F.tile(490, 140))
	F.advance(sim, 20)
	sim:construction_tick()
	local ups = {}
	sim.try_build = function(_self, id, kind_name, t)
		table.insert(ups, { kind_name, t })
		return true
	end
	sim.o_gold[N1] = 100000000
	ai.last_build[N1] = -1000
	local tiles = sim.o_tiles[N1]
	sim.o_tiles[N1] = 1 -- 1 structure x 1500 full-size tiles > 1 x K_AREA
	sim.playing_since = sim.tick - 3000
	ai:_consider_build(sim, N1, 3000)
	sim.o_tiles[N1] = tiles
	expect(
		#ups == 1 and ups[1][1] == "city" and ups[1][2] == c1.tile,
		"crowded: upgrade the existing city (1 city → city chosen)"
	)
	sim.try_build = nil
	-- the real path: a port on the coast, gold charged
	ai.last_build[N1] = -1000
	local before = sim:struct_total()
	local g0 = sim.o_gold[N1]
	ai:_consider_build(sim, N1, 3000)
	local newest = sim.struct_list[#sim.struct_list]
	expect(
		sim:struct_total() == before + 1
			and newest.kind == Defs.S_CITY
			and newest.owner == N1
			and near(g0 - sim.o_gold[N1], 250000),
		"real build: a second city for 250K"
	)
	F.advance(sim, 20)
	sim:construction_tick()
	ai.last_build[N1] = -1000
	ai:_consider_build(sim, N1, 3000)
	newest = sim.struct_list[#sim.struct_list]
	expect(
		sim:struct_total() == before + 2
			and newest.kind == Defs.S_PORT
			and sim.map.coastal
			and buffer.readu8(sim.map.coastal, newest.tile) == 1,
		"then a port on the coast (2 cities)"
	)
	before += 1
	expect(ai.last_build[N1] == sim.tick, "last_build stamped")
	ai:_consider_build(sim, N1, 3000)
	expect(sim:struct_total() == before + 1, "20-tick build gap")
end

-- =============================================================================================
print("human protection / grace")
do
	local sim = F.new_sim(3)
	sim.difficulty = 1
	local N1 = F.owner(sim, "Nation", Defs.KIND_NATION, 0, 100000)
	local H = F.owner(sim, "Human", Defs.KIND_HUMAN, 0, 100000)
	F.claim(sim, N1, 700, 120, 5)
	F.claim(sim, H, 720, 120, 5)
	sim.o_spawn_tile[N1] = F.tile(700, 120)
	sim.o_spawn_tile[H] = F.tile(720, 120)
	local ai = SimAI.new()
	ai:setup(sim)
	ai.grace_jitter[N1] = 100
	-- the grace distance is measured in tiles of the original grid (map tiles / LEGACY_LIN)
	local L = sim.R.LEGACY_LIN
	local dist = Defs.trunc(math.sqrt(sim.range_d2(F.tile(700, 120), F.tile(720, 120))) / L)
	local grace = Rules.human_grace_ticks(1)
		+ 100
		+ math.clamp((dist - Rules.HUMAN_GRACE_NEAR) * Rules.HUMAN_GRACE_PER_TILE, 0, Rules.HUMAN_GRACE_MAX_EXTRA)
	expect(
		not ai:_may_attack_human(sim, N1, H, grace - 1) and ai:_may_attack_human(sim, N1, H, grace),
		"grace = 3 min (Standard) + jitter + distance extra"
	)
	ai.attackers_on[H] = Rules.MAX_AI_WARS_ON_HUMAN[1]
	expect(not ai:_may_attack_human(sim, N1, H, grace + 1000), "at most 2 AI nations at war with a human (Standard)")
	sim.o_spawn_tile[H] = F.tile(900, 120)
	ai.attackers_on[H] = 0
	local far = Defs.trunc(math.sqrt(sim.range_d2(F.tile(700, 120), F.tile(900, 120))) / L)
	local g2 = Rules.human_grace_ticks(1) + 100 + math.clamp((far - 40) * 3, 0, 1200)
	expect(
		not ai:_may_attack_human(sim, N1, H, g2 - 1) and ai:_may_attack_human(sim, N1, H, g2),
		"distant nations wait longer (≤ 2 min extra)"
	)
	expect(Rules.human_grace_ticks(0) == 3000 and Rules.human_grace_ticks(2) == 1200, "grace 5 / 3 / 2 min")
end

-- =============================================================================================
print("warship behaviour / alliance replies")
do
	local sim = F.new_sim(4)
	sim.difficulty = 2
	local N1 = F.owner(sim, "Nation", Defs.KIND_NATION, 10000000, 100000)
	local N2 = F.owner(sim, "Other", Defs.KIND_NATION, 10000000, 100000)
	F.claim(sim, N1, 497, 146, 7)
	F.claim(sim, N2, 500, 159, 7)
	local ai = SimAI.new()
	ai:setup(sim)
	local coast = {}
	for _, t in F.coast_tiles() do
		if buffer.readi32(sim.owner, t * 4) == N1 and sim.map:coast_body_of(t) == 1 then
			table.insert(coast, t)
		end
	end
	expect(not ai:_tracks_ships(sim, N1), "no port built yet: not tracking")
	local p = sim:add_struct(Defs.S_PORT, N1, coast[1])
	F.advance(sim, 50)
	sim:construction_tick()
	expect(ai:_tracks_ships(sim, N1), "nation with a port tracks ships (Hard)")
	local sea = sim.nav:water_next_to(coast[1], 1)
	local built = 0
	for _ = 1, 40 do
		local before = sim.o_warships[N1]
		ai:_retaliate(sim, N1, sea, N2)
		if sim.o_warships[N1] > before then
			built += 1
		end
		sim.o_gold[N1] = 10000000
		if sim.o_warships[N1] >= 10 then
			break
		end
	end
	expect(built >= 5, string.format("Hard: retaliation builds warships ~50 %% of the time (%d)", built))
	expect(sim.o_warships[N1] <= 10, "fleet cap 10")
	sim.difficulty = 0
	expect(not ai:_tracks_ships(sim, N1), "Relaxed never tracks")
	sim.difficulty = 1
	-- move nearest instead of building at the cap
	sim.o_warships[N1] = 10
	local w = sim.warship_list[1]
	if w then
		w.patrol = sim:unit_tile(w)
		local moved_before = w.manual_tick
		ai:_retaliate(sim, N1, sea, N2)
		expect(
			w.manual_tick ~= moved_before or w.patrol == sea or sim.warship_list[2].patrol == sea,
			"at the cap: re-task the nearest warship"
		)
	end
	-- alliance replies
	sim.o_tiles[N1] = 100
	sim.o_tiles[N2] = 200
	local acc = 0
	local runs = 4000
	for _ = 1, runs do
		if ai:_accept(sim, N1, N2) then
			acc += 1
		end
	end
	-- p = 0.3 + 0.35 (ratio > 1.5) + bias(Standard 0) = 0.65
	expect(math.abs(acc / runs - 0.65) < 0.04, string.format("acceptance probability 0.65 (%.3f)", acc / runs))
	sim:add_grudge(N1, N2, 600)
	expect(not ai:_accept(sim, N1, N2), "never with a grudge")
	-- queue_reply delay 20..45 ticks
	sim:add_request(N2, N1)
	ai:queue_reply(sim, N2, N1)
	local r = ai.replies[1]
	expect(r[1] >= sim.tick + 20 and r[1] <= sim.tick + 45 and r[2] == N2 and r[3] == N1, "reply due in 20..45 ticks")
	local _ = p
end

-- =============================================================================================
print("nuke decisions")
do
	local sim = F.new_sim(5)
	sim.difficulty = 1
	local P = F.owner(sim, "Power", Defs.KIND_NATION, 0, 100000)
	F.claim(sim, P, 730, 110, 41.5) -- borders N1 (disks 1 tile apart on the original grid)
	local N1 = F.owner(sim, "Nation", Defs.KIND_NATION, 100000000, 100000)
	F.claim(sim, N1, 680, 100, 10)
	sim.o_cap[N1] = 500000
	sim.o_cap[P] = 500000
	local silo = sim:add_struct(Defs.S_SILO, N1, F.tile(680, 100))
	F.advance(sim, 100)
	sim:construction_tick()
	local ai = SimAI.new()
	ai:setup(sim)
	local launched = {}
	local real_launch = sim.launch_nuke
	sim.launch_nuke = function(self, id, kind_name, t)
		table.insert(launched, { id, kind_name, t })
		return real_launch(self, id, kind_name, t)
	end
	local function think(age)
		sim.playing_since = sim.tick - age
		sim:scan_border(N1, 400)
		ai:_consider_nuke(sim, N1, age)
	end
	expect(sim.o_tiles[P] > 2500 and sim.o_tiles[P] >= 400, "big neighbour")
	think(3000)
	expect(#launched == 0, "no nukes before NUKE_AGE (6 min on Standard)")
	think(4000)
	expect(#launched == 0, "no nukes on a neighbour we are not at war with")
	sim:add_grudge(N1, P, 600)
	think(4000)
	expect(
		#launched == 1 and launched[1][2] == "hydrogen" and buffer.readi32(sim.owner, launched[1][3] * 4) == P,
		"at war + rich + target > 2500 tiles: hydrogen on its land"
	)
	expect(
		ai.last_nuke[N1] == sim.tick and ai.nuke_cool[P] == sim.tick + SimAI.NUKE_TARGET_COOL,
		"last_nuke / nuke_cool"
	)
	F.advance(sim, 100)
	think(4100)
	expect(#launched == 1, "NUKE_GAP 3 min between an AI's nukes")
	-- leader with >= 35 % land and MIRV money → MIRV
	F.advance(sim, 2000)
	sim:add_grudge(N1, P, 600)
	ai.nuke_cool[P] = 0
	ai.leader = P
	silo.shots = {}
	local real_share = sim.land_share
	sim.land_share = function(self, id)
		if id == P then
			return 0.4
		end
		return real_share(self, id)
	end
	think(6200)
	expect(#launched == 2 and launched[2][2] == "mirv", "MIRV at the leader holding >= 35 %")
	sim.land_share = real_share
	-- tribes are never nuke targets
	local sim2 = F.new_sim(6)
	local T = F.owner(sim2, "Tribe", Defs.KIND_TRIBE, 0, 100000)
	F.claim(sim2, T, 730, 110, 30)
	local N2 = F.owner(sim2, "Nation", Defs.KIND_NATION, 100000000, 100000)
	F.claim(sim2, N2, 680, 100, 10)
	sim2:add_struct(Defs.S_SILO, N2, F.tile(680, 100))
	F.advance(sim2, 100)
	sim2:construction_tick()
	local ai2 = SimAI.new()
	ai2:setup(sim2)
	sim2:add_grudge(N2, T, 600)
	sim2.playing_since = sim2.tick - 5000
	sim2:scan_border(N2, 400)
	ai2:_consider_nuke(sim2, N2, 5000)
	expect(sim2.nukes_launched == 0, "tribes are never nuked")
end

-- =============================================================================================
print("attack cadence by difficulty (real match)")
do
	local Sim = require("../src/shared/Core/Sim")
	local map = WorldMap.shared()
	for d = 0, 2 do
		local sim = Sim.new(map, { seed = 7, difficulty = d, tribes = 40, max_humans = 0 })
		local ai = sim.ai
		local orig = ai._attack_due
		local dues = {}
		ai._attack_due = function(self, s, id)
			local r = orig(self, s, id)
			if r then
				local l = dues[id]
				if l == nil then
					l = {}
					dues[id] = l
				end
				table.insert(l, s.tick)
			end
			return r
		end
		-- Tribes: a tribe acts exactly on tick % attackRate == attackTick (attackRate 40-79).
		local tribe_ticks = {}
		for _, name in { "_tribe_first", "_think_tribe" } do
			local f = ai[name]
			ai[name] = function(self, s, id)
				local l = tribe_ticks[id]
				if l == nil then
					l = {}
					tribe_ticks[id] = l
				end
				table.insert(l, s.tick)
				return f(self, s, id)
			end
		end
		for _ = 1, 1500 do
			sim:step()
		end
		local lo, hi = SimAI.NATION_ATTACK_RATE[d][1], SimAI.NATION_ATTACK_RATE[d][2]
		local rate_ok, gap_ok, n_int, sum_excess = true, true, 0, 0
		local tribe_ok, tribe_n = true, 0
		for id, l in tribe_ticks do
			local rate, at = ai.attack_rate[id], ai.attack_tick[id]
			if sim.o_kind[id] ~= Defs.KIND_TRIBE or rate < 40 or rate > 79 or at < 0 or at >= rate then
				tribe_ok = false
			end
			if l[1] - sim.playing_since > rate then
				tribe_ok = false
			end
			for i, t in l do
				if t % rate ~= at or (i > 1 and t - l[i - 1] ~= rate) then
					tribe_ok = false
				end
				tribe_n += 1
			end
		end
		for id, l in dues do
			local rate = ai.attack_rate[id]
			if sim.o_kind[id] ~= Defs.KIND_NATION or rate < lo or rate > hi then
				rate_ok = false
			end
			for i = 2, #l do
				local g = l[i] - l[i - 1]
				if g < rate then
					gap_ok = false
				end
				n_int += 1
				sum_excess += g - rate
			end
		end
		expect(rate_ok, string.format("difficulty %d: attackRate nations %d-%d", d, lo, hi))
		expect(
			tribe_ok and tribe_n > 500,
			string.format("difficulty %d: tribes act on tick %% attackRate (40-79) == attackTick only (%d acts)", d, tribe_n)
		)
		expect(
			gap_ok and n_int > 50,
			string.format("difficulty %d: decisions >= attackRate apart (%d intervals)", d, n_int)
		)
		expect(
			n_int > 0 and sum_excess / n_int < 12,
			string.format(
				"difficulty %d: mean lateness %.1f ticks (think cadence 12-18)",
				d,
				if n_int > 0 then sum_excess / n_int else -1
			)
		)
	end
end

F.finish("simsys_ai")
