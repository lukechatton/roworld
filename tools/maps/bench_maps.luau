-- Map performance probe: build time, Luau heap per map / Sim / GameState, and Sim.step timing of an
-- AI-only match (the map's nations + its default tribes, Standard) on imported maps.
-- Run: .bin/lune run tools/maps/bench_maps.luau -- --maps=world,alps --minutes=10 [--tribes=N]
local process = require("@lune/process")
local WorldMap = require("../../src/shared/Core/WorldMap")
local Sim = require("../../src/shared/Core/Sim")
local GameState = require("../../src/shared/Core/GameState")

local maps = { "world" }
local minutes = 10
local tribes: number? = nil
for _, a in process.args do
	local k, v = string.match(a, "^%-%-([%w_]+)=(.*)$")
	if k == "maps" then
		maps = string.split(v, ",")
	elseif k == "minutes" then
		minutes = tonumber(v) or minutes
	elseif k == "tribes" then
		tribes = tonumber(v)
	end
end

local function heap_kb(): number
	return collectgarbage("count")
end

--- Bytes held in the buffer fields of `obj` (shallow), skipping buffers already counted in `seen`.
local function buffer_bytes(obj: any, seen: { [buffer]: boolean }): number
	local total = 0
	for _, v in obj do
		if typeof(v) == "buffer" and not seen[v] then
			seen[v] = true
			total += buffer.len(v)
		end
	end
	return total
end

for _, id in maps do
	local h0 = heap_kb()
	WorldMap.load_data(id)
	local h1 = heap_kb()
	local t0 = os.clock()
	local map = WorldMap.get(id)
	local t_map = os.clock() - t0
	local h2 = heap_kb()
	t0 = os.clock()
	local sim = Sim.new(map, { seed = 1, difficulty = 1, tribes = tribes, max_humans = 0 })
	local t_sim = os.clock() - t0
	local h3 = heap_kb()
	local gs = GameState.new(map)
	gs:load_snapshot(sim:snapshot())
	local h4 = heap_kb()
	local n = map.N
	print(
		string.format(
			"%s %dx%d = %d tiles (k_lin %.2f, land %d) | nations %d tribes %d",
			id,
			map.W,
			map.H,
			n,
			map.k_lin,
			map.land_count,
			sim.nation_count,
			sim.tribe_count
		)
	)
	print(
		string.format(
			"  build: map %.0f ms, Sim.new %.0f ms (nav regions %d)",
			t_map * 1000,
			t_sim * 1000,
			sim.nav.reg_count
		)
	)
	print(
		string.format(
			"  heap: data module %.1f MB, map %.1f MB (%.1f B/tile), Sim %.1f MB (%.1f B/tile incl. nav graph), GameState %.1f MB (%.1f B/tile)",
			(h1 - h0) / 1024,
			(h2 - h1) / 1024,
			(h2 - h1) * 1024 / n,
			(h3 - h2) / 1024,
			(h3 - h2) * 1024 / n,
			(h4 - h3) / 1024,
			(h4 - h3) * 1024 / n
		)
	)
	-- exact buffer accounting (tables not included): map, one Sim (+ its nav scratch and the
	-- shared nav graph), one GameState
	local seen = {}
	local b_map = buffer_bytes(map, seen)
	local b_nav = buffer_bytes(map._nav_graph or {}, seen)
	local b_sim = buffer_bytes(sim, seen) + buffer_bytes(sim.nav, seen)
	local b_gs = buffer_bytes(gs, seen)
	print(
		string.format(
			"  buffers: map %.1f B/tile, nav graph %.1f B/tile, Sim %.1f B/tile, GameState %.1f B/tile = %.1f B/tile (%.1f MB)",
			b_map / n,
			b_nav / n,
			b_sim / n,
			b_gs / n,
			(b_map + b_nav + b_sim + b_gs) / n,
			(b_map + b_nav + b_sim + b_gs) / 1048576
		)
	)
	local ticks = minutes * 600
	local times = table.create(ticks)
	local per_min = {}
	local acc = 0.0
	for i = 1, ticks do
		local a = os.clock()
		local d = sim:step()
		local dt = (os.clock() - a) * 1000
		times[i] = dt
		acc += dt
		gs:apply_delta(d)
		if i % 600 == 0 then
			local owned = 0
			for o = 1, sim.owner_total do
				owned += sim.o_tiles[o]
			end
			table.insert(
				per_min,
				string.format("m%d %.2fms %d%%", i // 600, acc / 600, math.floor(100 * owned / map.land_count))
			)
			acc = 0
		end
		if sim.phase == 2 then
			print("  match over at tick " .. i)
			break
		end
	end
	local done = #times
	table.sort(times)
	local sum = 0
	for _, v in times do
		sum += v
	end
	print(
		string.format(
			"  step: avg %.2f ms, p50 %.2f, p95 %.2f, p99 %.2f, max %.2f over %d ticks",
			sum / done,
			times[math.max(1, done // 2)],
			times[math.max(1, math.floor(done * 0.95))],
			times[math.max(1, math.floor(done * 0.99))],
			times[done],
			done
		)
	)
	print("  per minute (avg step, land owned): " .. table.concat(per_min, " "))
	print(string.format("  heap after the match: %.1f MB", heap_kb() / 1024))
	sim = nil
	gs = nil
	WorldMap.release(id)
end
