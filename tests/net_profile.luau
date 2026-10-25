-- Profiling helper: where do delta bytes and encode time go?
-- .bin/lune run tests/net_profile.luau [ticks] [map=pangaea]
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local process = require("@lune/process")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
U.use_zstd(Protocol)
local ticks = tonumber(process.args[1]) or 600
local map = WorldMap.get(process.args[2] or "pangaea")
local sim =
	Sim.new(map, { seed = 7, difficulty = 1, tribes = 90, max_humans = 32, time_limit_s = 2400, spawn_ticks = 200 })
local enc, z, n = 0, 0, 0
local b_tiles, b_stats, b_ev, b_total, b_z = 0, 0, 0, 0, 0
local ntiles, nstats = 0, 0
local by_type = {}
for i = 1, ticks do
	local d = sim:step()
	local a = os.clock()
	local raw = Protocol.encode_delta(d, nil, map.W)
	local b = os.clock()
	local zz = Protocol.compress(raw)
	local c = os.clock()
	enc += b - a
	z += c - b
	b_total += buffer.len(raw)
	b_z += buffer.len(zz)
	local only_tiles = Protocol.encode_delta({ tiles = d.tiles })
	local only_stats = if d.stats then Protocol.encode_delta({ stats = d.stats }) else nil
	b_tiles += buffer.len(only_tiles)
	ntiles += #d.tiles
	if only_stats then
		b_stats += buffer.len(only_stats)
		nstats += 1
	end
	for _, e in d.ev do
		local eb = buffer.len(Protocol._write_value(e))
		by_type[e[1]] = (by_type[e[1]] or 0) + eb
		b_ev += eb
	end
end
print(("encode %.3f ms/tick, zstd %.3f ms/tick"):format(enc * 1000 / ticks, z * 1000 / ticks))
print(
	("raw %.1f KB/s, wire %.1f KB/s | tiles %.1f KB/s (%.1f tiles/tick, %.2f B/tile) | stats %.1f KB/s (%d rows) | ev %.1f KB/s"):format(
		b_total / ticks * 10 / 1024,
		b_z / ticks * 10 / 1024,
		b_tiles / ticks * 10 / 1024,
		ntiles / ticks,
		b_tiles / math.max(1, ntiles),
		b_stats / ticks * 10 / 1024,
		nstats,
		b_ev / ticks * 10 / 1024
	)
)
local rows = {}
for k, v in by_type do
	table.insert(rows, { k, v })
end
table.sort(rows, function(x, y)
	return x[2] > y[2]
end)
local parts = {}
for _, r in rows do
	table.insert(parts, ("ev%d=%.2fKB/s"):format(r[1], r[2] / ticks * 10 / 1024))
end
print(table.concat(parts, " "))
