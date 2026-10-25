-- Full matches on imported maps (flat, no wrap): nations from the manifest + tribes + a scripted
-- human (spawn, expansion, wars, cities, boats), then invariants — tiles in range and only on
-- contestable land, per-owner tile counts = the grid, border lists exact, unit paths dense and never
-- across the map edge, the client mirror (deltas through the wire protocol) equal to the Sim — and
-- determinism (same seed → same state hash). Also direct no-wrap checks of the neighbour code.
-- Run: .bin/lune run tests/sim_matches.luau [ticks]
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local process = require("@lune/process")
local serde = require("@lune/serde")
local Defs = require("../src/shared/Core/Defs")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local SimState = require("../src/shared/Core/SimState")
local GameState = require("../src/shared/Core/GameState")
local Protocol = require("../src/shared/Net/Protocol")

Protocol.set_codec({
	compress = function(b: buffer): buffer
		return buffer.fromstring(serde.compress("zstd", buffer.tostring(b)))
	end,
	decompress = function(b: buffer, _n: number): buffer
		return buffer.fromstring(serde.decompress("zstd", buffer.tostring(b)))
	end,
})

local TICKS = tonumber(process.args[1]) or 400
local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end
local readi32 = buffer.readi32
local readu8 = buffer.readu8

--- Cheap FNV-style hash of the match state (owner grid + per-owner numbers + units / structures).
local function state_hash(sim: any): string
	local h1, h2 = 2166136261, 5381
	local owner = sim.owner
	for i = 0, sim.N - 1, 1 do
		local v = readi32(owner, i * 4)
		if v ~= 0 then
			h1 = (bit32.bxor(h1, v + i) * 16777619) % 4294967296
			h2 = (h2 * 33 + v * 7 + i) % 4294967296
		end
	end
	local parts = { tostring(h1), tostring(h2) }
	for id = 1, sim.owner_total do
		table.insert(
			parts,
			string.format(
				"%d:%d:%d:%d",
				sim.o_tiles[id],
				math.floor(sim.o_troops[id]),
				math.floor(sim.o_gold[id]),
				sim.o_alive[id]
			)
		)
	end
	table.insert(parts, tostring(sim.n_structs) .. "/" .. tostring(sim.n_units) .. "/" .. tostring(#sim.attacks))
	return table.concat(parts, ",")
end

--- A free start for the human: land far (>= 60 tiles) from every spawned owner.
local function human_start_tile(sim: any): number
	local map = sim.map
	local best, bd = -1, -1
	for k = 0, map.land_count - 1, 97 do
		local t = map:land_tile(k)
		if readi32(sim.owner, t * 4) ~= 0 then
			continue
		end
		local d = math.huge
		for o = 1, sim.owner_total do
			local st = sim.o_spawn_tile[o]
			if sim.o_spawned[o] == 1 and st >= 0 then
				d = math.min(d, sim.dist2(st, t))
			end
		end
		if d > bd then
			bd = d
			best = t
		end
	end
	return best
end

--- One match; returns the sim, the mirror and the per-tick timing.
local function run(map_id: string, seed: number, ticks: number, with_mirror: boolean): (any, any, number)
	local map = WorldMap.get(map_id)
	local sim = Sim.new(map, { seed = seed, difficulty = 1, max_humans = 1 })
	local me = sim:add_human("tester", "Tester")
	local gs = nil
	if with_mirror then
		gs = GameState.new(map)
		-- the snapshot travels through the wire protocol like a late joiner's
		local snap = Protocol.decode_snapshot(Protocol.compress(Protocol.encode_snapshot(sim:snapshot())))
		gs:load_snapshot(snap)
	end
	local start = human_start_tile(sim)
	assert(start >= 0, "no free start")
	sim:human_start(me, start)
	local rng_i = 0
	local t0 = os.clock()
	for _ = 1, ticks do
		if sim.phase == Defs.PHASE_PLAYING and sim.o_alive[me] == 1 and sim.o_spawned[me] == 1 then
			local tick = sim.tick
			if tick % 15 == 0 then
				sim:scan_border(me, 2000)
				if sim.sc_neutral_tile >= 0 then
					sim:submit(me, { type = "attack", tile = sim.sc_neutral_tile, ratio = 0.4 })
				elseif #sim.sc_list > 0 and tick % 45 == 0 then
					local p = sim.sc_list[1 + (tick // 45) % #sim.sc_list]
					sim:submit(me, { type = "attack", tile = sim.sc_tile[p], ratio = 0.3 })
				end
			end
			if tick % 40 == 0 and sim.o_gold[me] >= Rules.build_cost("city", sim:cost_count(me, Defs.S_CITY)) then
				sim:submit(me, { type = "build", kind = "city", tile = sim:centre_tile(me) })
			end
			if tick % 60 == 0 and sim.o_coast[me] > 0 then
				-- a boat to a random foreign coast
				rng_i += 1
				local c = map:coast_tile((rng_i * 7919) % map.coast_count)
				if readi32(sim.owner, c * 4) ~= me then
					sim:submit(me, { type = "boat", tile = c, ratio = 0.2 })
				end
			end
			if tick % 90 == 0 and sim.o_coast[me] > 0 then
				sim:submit(me, { type = "build", kind = "port", tile = sim:own_coast_tile(me) })
			end
		end
		local d = sim:step()
		if gs ~= nil then
			-- the delta goes through the wire protocol (paths use the map width)
			local wire = Protocol.decode_delta(Protocol.compress(Protocol.encode_delta(d, nil, sim.W)))
			gs:apply_delta(wire)
		end
	end
	return sim, gs, (os.clock() - t0) * 1000 / ticks
end

--- Invariants of a finished run.
local function check(sim: any, gs: any, label: string)
	local map = sim.map
	local W, H, N = sim.W, sim.H, sim.N
	local counts = {}
	local bad_owner, off_land = 0, 0
	local owner = sim.owner
	for t = 0, N - 1 do
		local o = readi32(owner, t * 4)
		if o ~= 0 then
			if o < 0 or o > sim.owner_total then
				bad_owner += 1
			else
				counts[o] = (counts[o] or 0) + 1
			end
			if readu8(map.land, t) ~= 1 then
				off_land += 1
			end
		end
	end
	expect(bad_owner == 0, label .. ": owner ids in range")
	expect(off_land == 0, label .. ": only contestable land is owned")
	local tiles_ok, total = true, 0
	for id = 1, sim.owner_total do
		if (counts[id] or 0) ~= sim.o_tiles[id] then
			tiles_ok = false
		end
		total += sim.o_tiles[id]
	end
	expect(tiles_ok and total <= map.contestable_count, label .. ": o_tiles = grid counts (" .. total .. " owned)")
	-- border lists: exactly the owned tiles with a differently-owned (or unowned) land neighbour
	local border_ok = true
	local in_lists = 0
	for id = 1, sim.owner_total do
		local n = 0
		local b = sim.bhead[id]
		while b ~= -1 do
			n += 1
			if readi32(owner, b * 4) ~= id or not SimState._is_border(sim, b, id) then
				border_ok = false
			end
			b = readi32(sim.bnext, b * 4)
			if n > N then
				border_ok = false
				break
			end
		end
		if n ~= sim.bcount[id] then
			border_ok = false
		end
		in_lists += n
	end
	local flagged = 0
	for t = 0, N - 1 do
		local o = readi32(owner, t * 4)
		if o ~= 0 then
			local isb = SimState._is_border(sim, t, o)
			if isb ~= (readu8(sim.in_border, t) == 1) then
				border_ok = false
			end
			if isb then
				flagged += 1
			end
		end
	end
	expect(border_ok and flagged == in_lists, label .. ": border lists exact (" .. in_lists .. " border tiles)")
	-- unit paths: in range, dense, never across the map edge
	local paths_ok, units = true, 0
	for _, u in sim.unit_list do
		if u.dead then
			continue
		end
		units += 1
		local p = u.path
		for i = 1, #p do
			local t = p[i]
			if t < 0 or t >= N then
				paths_ok = false
			elseif i > 1 then
				local q = p[i - 1]
				if math.abs(t % W - q % W) > 1 or math.abs(t // W - q // W) > 1 then
					paths_ok = false
				end
			end
		end
	end
	expect(paths_ok, label .. ": " .. units .. " unit paths dense and inside the map")
	for _, s in sim.struct_list do
		if not s.dead and (s.tile < 0 or s.tile >= N or readi32(owner, s.tile * 4) ~= s.owner) then
			expect(false, label .. ": structure on its owner's tile")
			break
		end
	end
	if gs ~= nil then
		expect(
			buffer.tostring(gs.owner) == buffer.tostring(sim.owner),
			label .. ": mirror owner grid = Sim (via the protocol)"
		)
		expect(buffer.tostring(gs.flags) == buffer.tostring(sim.flags), label .. ": mirror flags = Sim")
		local mirror_ok = true
		for id = 1, sim.owner_total do
			local o = gs.owners[id]
			if o == nil or o.tiles ~= sim.o_tiles[id] then
				mirror_ok = false
			end
		end
		expect(mirror_ok, label .. ": mirror tile counts")
		local nstruct = 0
		for _ in gs.structures do
			nstruct += 1
		end
		expect(nstruct == sim.n_structs, label .. ": mirror structures (" .. nstruct .. ")")
	end
	local _ = H
end

-- ---------------------------------------------------------------------------------------------
-- No wrap: the neighbour code on the map edges (direct checks on a scratch owner grid)
-- ---------------------------------------------------------------------------------------------
do
	local map = WorldMap.get("pangaea")
	local W, N = map.W, map.N
	local grid = buffer.create(N * 4)
	local land = buffer.create(N)
	buffer.fill(land, 0, 1)
	local fake = { owner = grid, land = land, W = W, H = map.H, N = N }
	local row = 500
	local left, right = row * W, row * W + W - 1
	buffer.writei32(grid, left * 4, 1)
	buffer.writei32(grid, right * 4, 2)
	expect(
		not SimState.touches(fake, left, 2) and not SimState.touches(fake, right, 1),
		"no wrap: edge columns don't touch"
	)
	buffer.writei32(grid, (left + 1) * 4, 1)
	buffer.writei32(grid, (left + W) * 4, 1)
	buffer.writei32(grid, (left - W) * 4, 1)
	expect(not SimState._is_border(fake, left, 1), "no wrap: the map edge is not a border")
	expect(SimState._is_border(fake, right, 2), "a tile with foreign neighbours is a border")
	local sim = Sim.new(map, { seed = 1, tribes = 0, max_humans = 0 })
	local edge = 300 * W + 1
	for _, t in sim:disk_tiles(edge, 6, false) do
		if t % W > 7 then
			expect(false, "no wrap: disk_tiles near x = 0 stays on the left")
			break
		end
	end
	expect(#sim:disk_tiles(edge, 6, false) < 113, "disk clipped at the edge")
	local fake2 = { W = W, N = N, owner = grid }
	local _ = fake2
end

-- ---------------------------------------------------------------------------------------------
-- Matches
-- ---------------------------------------------------------------------------------------------
for _, case in { { "pangaea", 11, TICKS }, { "world", 5, math.max(200, TICKS // 2) } } do
	local id, seed, ticks = case[1], case[2], case[3]
	print(("%s: %d ticks"):format(id, ticks))
	local sim, gs, ms = run(id, seed, ticks, true)
	local alive, nations, tribes = 0, 0, 0
	for o = 1, sim.owner_total do
		if sim.o_alive[o] == 1 then
			alive += 1
		end
		if sim.o_kind[o] == Defs.KIND_NATION then
			nations += 1
		elseif sim.o_kind[o] == Defs.KIND_TRIBE then
			tribes += 1
		end
	end
	local me = sim.humans[1]
	print(
		("  %.2f ms/tick | owners %d (nations %d, tribes %d, alive %d) | human %d tiles, %d structures | attacks %d units %d"):format(
			ms,
			sim.owner_total,
			nations,
			tribes,
			alive,
			sim.o_tiles[me],
			sim.n_structs,
			#sim.attacks,
			sim.n_units
		)
	)
	expect(nations == #sim.map.nations and sim.nation_count == nations, id .. ": every manifest nation created")
	expect(tribes == Sim.default_tribes(sim.map) and tribes == 400, id .. ": 400 tribes (the default bots)")
	local spawned_near = 0
	for o = 1, sim.owner_total do
		if sim.o_kind[o] == Defs.KIND_NATION then
			local nd = sim.map.nations[o]
			if
				nd.tile >= 0
				and sim.o_spawn_tile[o] >= 0
				and sim.dist2(nd.tile, sim.o_spawn_tile[o]) <= (2 * sim.R.NATION_SPAWN_DELTA) ^ 2 * 2
			then
				spawned_near += 1
			end
		end
	end
	expect(
		spawned_near >= nations * 0.9,
		("%s: %d/%d nations started near their manifest coordinates"):format(id, spawned_near, nations)
	)
	expect(
		sim.phase == Defs.PHASE_PLAYING and sim.o_spawned[me] == 1 and sim.o_tiles[me] > 20,
		id .. ": the human spawned and expanded"
	)
	check(sim, gs, id)
	-- determinism
	local sim2 = run(id, seed, ticks, false)
	expect(state_hash(sim) == state_hash(sim2), id .. ": same seed → same state")
	local sim3 = run(id, seed + 1, math.min(ticks, 150), false)
	expect(state_hash(sim3) ~= state_hash(sim), id .. ": another seed → another match")
end

print(fails == 0 and "sim_matches ok" or ("sim_matches FAILED " .. fails))
if fails > 0 then
	error("failures")
end
