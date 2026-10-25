-- sim-core: GameState mirror test. A GameState built from Sim.snapshot() receives every delta and
-- must equal the Sim's state (owner grid, flags, owners + stats, structures, roads, units, nukes,
-- shells, SAM missiles, attacks, alliances, requests, built counts…) at many ticks; a second mirror
-- loaded from a mid-game snapshot must converge with the first. A scripted, very active human (lots
-- of gold) exercises builds, upgrades, boats, warships, nukes and diplomacy.
-- Runs on an imported map (default pangaea; --map=<id>).
-- Run: .bin/lune run tests/sim_mirror.luau [-- --ticks=3000 --seed=5 --map=pangaea]
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local process = require("@lune/process")
local Defs = require("../src/shared/Core/Defs")
local Rules = require("../src/shared/Core/Rules")
local Rng = require("../src/shared/Core/Rng")
local WorldMap = require("../src/shared/Core/WorldMap")
local GameState = require("../src/shared/Core/GameState")
local Sim = require("../src/shared/Core/Sim")

local ticks, seed, map_id = 3000, 5, "pangaea"
for _, a in process.args do
	local k, v = string.match(a, "^%-%-(%w+)=(.*)$")
	if k == "ticks" then
		ticks = tonumber(v) or ticks
	elseif k == "seed" then
		seed = tonumber(v) or seed
	elseif k == "map" then
		map_id = v
	end
end

local fails = 0
local checks = 0
local function fail(what: string)
	fails += 1
	if fails <= 25 then
		print("FAIL " .. what)
	end
end
local readi32 = buffer.readi32
local trunc = Defs.trunc

local function count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function same_path(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function check(sim: any, gs: any, label: string, stats_fresh: boolean)
	checks += 1
	if buffer.tostring(gs.owner) ~= buffer.tostring(sim.owner) then
		fail(label .. ": owner grid")
	end
	if buffer.tostring(gs.flags) ~= buffer.tostring(sim.flags) or gs.fallout_count ~= sim.fallout_count then
		fail(label .. ": flags / fallout_count")
	end
	if
		gs.tick ~= sim.tick
		or gs.phase ~= sim.phase
		or gs.playing_since ~= sim.playing_since
		or gs.mirvs_launched ~= sim.mirvs_launched
	then
		fail(label .. ": tick/phase/playing_since/mirvs")
	end
	for id = 1, sim.owner_total do
		local o = gs.owners[id]
		if o == nil then
			fail(label .. ": owner missing " .. id)
			continue
		end
		if
			o.tiles ~= sim.o_tiles[id]
			or o.alive ~= (sim.o_alive[id] == 1)
			or o.name ~= sim.o_name[id]
			or o.rgba ~= sim.o_color[id]
			or o.kind ~= sim.o_kind[id]
		then
			fail(label .. ": owner " .. id)
		end
		if o.traitor_until ~= sim.o_traitor_until[id] then
			fail(label .. ": traitor_until " .. id)
		end
		if stats_fresh and o.alive and (sim.o_spawned[id] == 1 or sim.o_kind[id] == Defs.KIND_HUMAN) then
			if
				o.troops ~= trunc(sim.o_troops[id])
				or o.gold ~= sim:_gold_int(id)
				or o.max_troops ~= trunc(sim.o_cap[id])
				or o.income ~= trunc(sim.o_income[id] + sim.o_bonus_rate[id])
			then
				fail(label .. ": stats " .. id)
			end
		end
	end
	if count(gs.structures) ~= sim:struct_total() then
		fail(label .. ": structure count")
	end
	for sid, s in sim.structs do
		local g = gs.structures[sid]
		if
			g == nil
			or g.kind ~= s.kind
			or g.owner ~= s.owner
			or g.tile ~= s.tile
			or g.level ~= s.level
			or g.active_tick ~= s.active_tick
		then
			fail(label .. ": structure " .. sid)
		end
	end
	if count(gs.roads) ~= sim:road_total() then
		fail(label .. ": road count")
	end
	for rid, r in sim.roads do
		local g = gs.roads[rid]
		if g == nil or g.a ~= r[1] or g.b ~= r[2] then
			fail(label .. ": road " .. rid)
		end
	end
	if count(gs.units) ~= sim:unit_total() then
		fail(label .. ": unit count")
	end
	for _, u in sim.unit_list do
		if u.dead then
			continue
		end
		local g = gs.units[u.uid]
		if
			g == nil
			or g.kind ~= u.kind
			or g.owner ~= u.owner
			or not same_path(g.path, u.path)
			or g.start_tick ~= u.start_tick
			or g.ticks_per_tile_x100 ~= u.tpt
		then
			fail(label .. ": unit " .. u.uid)
		elseif
			u.kind == Defs.U_WARSHIP
			and (
				g.hp ~= u.hp
				or g.max_hp ~= u.max_hp
				or g.veterancy ~= u.vet
				or g.state ~= u.state
				or g.patrol_tile ~= u.patrol
			)
		then
			fail(label .. ": warship " .. u.uid)
		end
	end
	local live_nukes = 0
	for _, n in sim.nukes do
		if not n.dead then
			live_nukes += 1
			local g = gs.nukes[n.uid]
			if
				g == nil
				or g.kind ~= n.kind
				or g.owner ~= n.owner
				or g.to_tile ~= n.to_tile
				or g.launch_tick ~= n.launch_tick
			then
				fail(label .. ": nuke " .. n.uid)
			end
		end
	end
	if count(gs.nukes) ~= live_nukes then
		fail(label .. ": nuke count")
	end
	if count(gs.shells) ~= #sim.shells then
		fail(label .. ": shell count")
	end
	if count(gs.attacks) ~= count(sim.attack_by_id) then
		fail(label .. ": attack count")
	end
	for aid, a in sim.attack_by_id do
		local g = gs.attacks[aid]
		-- troops: as last sent (ATTACK events every 10 ticks) — or current, right after a snapshot load
		if
			g == nil
			or g.attacker ~= a.attacker
			or g.target ~= a.target
			or (g.troops ~= a.sent_troops and g.troops ~= trunc(a.troops))
		then
			fail(label .. ": attack " .. aid)
		end
	end
	if count(gs.alliances) ~= count(sim.alliances) or count(gs.requests) ~= count(sim.requests) then
		fail(label .. ": alliances / requests")
	end
	for k in sim.alliances do
		if not gs.alliances[k] then
			fail(label .. ": alliance " .. k)
		elseif gs.alliance_expires[k] ~= sim.ally_expires[k] or (gs.alliance_ext[k] or 0) ~= sim.ally_ext[k] then
			fail(label .. ": alliance expiry / renewal " .. k)
		end
	end
	for k, made in sim.requests do
		if gs.requests[k] ~= made then
			fail(label .. ": request tick " .. k)
		end
	end
	for id = 1, sim.owner_total do
		for k = 0, Rules.BUILT_SLOTS - 1 do
			if gs:built_count(id, k) ~= sim.o_built[id * 16 + k] then
				fail(label .. (": built %d/%d"):format(id, k))
			end
		end
		local al = sim:allies_of(id)
		local gl = gs:allies_of(id)
		if #al ~= #gl then
			fail(label .. ": allies_of " .. id)
		else
			for i = 1, #al do
				if al[i] ~= gl[i] then
					fail(label .. ": allies_of order " .. id)
				end
			end
		end
	end
end

local map = WorldMap.get(map_id)
local sim = Sim.new(map, { seed = seed, difficulty = 2, tribes = 80, max_humans = 1 })
local hid = sim:add_human("mirror", "Mirror")
local gs = GameState.new(map)
gs:load_snapshot(sim:snapshot())
gs.local_owner = hid
check(sim, gs, "fresh", true)
local start = -1
for k = 0, map.land_count - 1 do
	local t = map:land_tile(k)
	if
		t // map.W > 100
		and readi32(sim.owner, t * 4) == 0
		and sim:_area_free(t, 8)
		and buffer.readu8(map.coastal, t) == 0
	then
		start = t
		break
	end
end
sim:human_start(hid, start)
local rng = Rng.new(seed * 7)
local gs2: any = nil
local saw = {}
for i = 1, ticks do
	if sim.phase == Defs.PHASE_PLAYING and sim.o_alive[hid] == 1 and i % 15 == 0 then
		sim.o_gold[hid] += 400000 -- a rich, busy human
		sim:scan_border(hid, 500)
		local roll = rng:randi() % 10
		if sim.sc_neutral_tile >= 0 and roll < 4 then
			sim:submit(hid, { type = "attack", tile = sim.sc_neutral_tile, ratio = 0.4 })
		elseif #sim.sc_list > 0 and roll < 6 then
			local p = sim.sc_list[rng:randi() % #sim.sc_list + 1]
			if rng:randf() < 0.3 then
				sim:submit(hid, { type = "ally_request", target = p })
			else
				sim:submit(hid, { type = "attack", tile = sim.sc_tile[p], ratio = 0.3 })
			end
		end
		local kinds = { "city", "port", "factory", "defense", "sam", "silo" }
		local k = kinds[rng:randi() % #kinds + 1]
		local site = sim:find_site(
			hid,
			Defs.struct_kind_from_name(k),
			if k == "port" then math.max(sim:own_coast_tile(hid), 0) else sim:centre_tile(hid),
			20,
			20
		)
		if site >= 0 then
			sim:submit(hid, { type = "build", kind = k, tile = site })
		elseif #gs:structures_of(hid, Defs.S_CITY) > 0 then
			local cs = gs:structures_of(hid, Defs.S_CITY)
			sim:submit(hid, { type = "build", kind = "city", tile = cs[rng:randi() % #cs + 1].tile })
		end
		if roll == 7 and sim:own_coast_tile(hid) >= 0 then
			sim:submit(hid, { type = "build", kind = "warship", tile = sim:own_coast_tile(hid) })
			sim:submit(hid, { type = "boat", tile = map:coast_tile(rng:randi() % map.coast_count), ratio = 0.1 })
		end
		if roll == 8 and gs:count_structures(hid, Defs.S_SILO) > 0 and #sim.sc_list > 0 then
			local p = sim.sc_list[1]
			sim:submit(
				hid,
				{ type = "nuke", kind = if rng:randf() < 0.2 then "mirv" else "atom", tile = sim.sc_tile[p] }
			)
		end
		for key in gs.requests do
			if key % 1024 == hid then
				sim:submit(hid, { type = "ally_reply", target = key // 1024, accept = rng:randf() < 0.5 })
			end
		end
		for _, a in sim:allies_of(hid) do
			if rng:randf() < 0.02 then
				sim:submit(hid, { type = "ally_break", target = a })
			end
		end
	end
	local d = sim:step()
	for _, e in d.ev do
		saw[e[1]] = (saw[e[1]] or 0) + 1
	end
	gs:apply_delta(d)
	if gs2 then
		gs2:apply_delta(d)
	end
	if i == 1000 then
		gs2 = GameState.new(map)
		gs2:load_snapshot(sim:snapshot())
		gs2.local_owner = hid
		check(sim, gs2, "late snapshot t=" .. sim.tick, false)
	end
	if i % 250 == 0 or i == 55 then
		check(sim, gs, "t=" .. sim.tick, sim.tick % 5 == 0)
		if gs2 then
			check(sim, gs2, "late mirror t=" .. sim.tick, sim.tick % 5 == 0)
		end
	end
	if sim.phase == Defs.PHASE_OVER then
		break
	end
end
local kinds = {}
for k = 0, 29 do
	if saw[k] then
		table.insert(kinds, k .. ":" .. saw[k])
	end
end
print(("  %d mirror checks over %d ticks; events seen %s"):format(checks, sim.tick, table.concat(kinds, " ")))
print(fails == 0 and "sim_mirror ok" or ("sim_mirror FAILED " .. fails))
if fails > 0 then
	error("failures")
end
