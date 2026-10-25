-- Public matches play their map a bit smaller: "world@80" builds World at 80 % of its width and
-- height from the same data (nearest-sample resample, shoreline recomputed), with k_lin scaled so
-- ranges stay the same in full-size tiles, nations moved with the map, and tribes in proportion to
-- the area. Lookups by id ignore the suffix.
require("./prelude")
local WorldMap = require("../src/shared/Core/WorldMap")
local MapList = require("../src/shared/Data/MapList")
local Rules = require("../src/shared/Core/Rules")
local Sim = require("../src/shared/Core/Sim")
local LobbyRules = require("../src/server/Lobbies/LobbyRules")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local base, s = WorldMap.split_id("world@80")
expect(base == "world" and s == 0.8, "split_id")
expect(select(2, WorldMap.split_id("world")) == 1.0, "no suffix: full size")
expect(MapList.get("world@80") == MapList.get("world"), "MapList ignores the suffix")
local id = LobbyRules.match_map_id("world")
expect(id == "world@" .. LobbyRules.MAP_SCALE_PCT, "public matches play " .. id)

local full = WorldMap.get("world")
local small = WorldMap.get("world@80")
expect(small.W == math.floor(full.W * 0.8 + 0.5) and small.H == math.floor(full.H * 0.8 + 0.5), string.format("%dx%d from %dx%d", small.W, small.H, full.W, full.H))
expect(small.id == "world@80" and math.abs(small.scale - 0.8) < 0.01, "id and scale")
expect(math.abs(small.k_lin - full.k_lin / small.scale) < 1e-6, "k_lin grows as the tiles cover more full-size tiles")
local land_ratio = small.land_count / full.land_count
expect(math.abs(land_ratio - 0.64) < 0.03, string.format("land keeps its share (%.3f of the tiles)", land_ratio))
-- shoreline bit consistent on the new grid
local bad = 0
for i = 0, small.N - 1, 97 do
	local b = buffer.readu8(small.tile_bytes, i)
	if b ~= 0x9F then
		local l = b >= 128
		local x = i % small.W
		local shore = false
		for _, n in { if x > 0 then i - 1 else -1, if x < small.W - 1 then i + 1 else -1, i - small.W, i + small.W } do
			if n >= 0 and n < small.N and (buffer.readu8(small.tile_bytes, n) >= 128) ~= l then
				shore = true
			end
		end
		if shore ~= (bit32.band(b, 0x40) ~= 0) then
			bad += 1
		end
	end
end
expect(bad == 0, "shoreline bit matches the new grid")
-- nations moved with the map
local moved = true
for i, n in small.nations do
	local f = full.nations[i]
	if n.x ~= nil and f.x ~= nil and math.abs(n.x - f.x * 0.8) > 1.5 then
		moved = false
	end
end
expect(moved, "nation starts scaled")
-- ranges in full-size tiles are the same: our tiles shrink by the scale
local R0, R1 = Rules.for_map(full), Rules.for_map(small)
expect(math.abs(R1.ROAD_MAX_TILES - R0.ROAD_MAX_TILES * small.scale) < 0.5, "train range scales with the build")
expect(Sim.default_tribes(small) == math.floor(Rules.DEFAULT_TRIBES * 0.64 + 0.5) and Sim.default_tribes(full) == Rules.DEFAULT_TRIBES, "tribes follow the area")
-- a small build runs a match
local sim = Sim.new(small, { seed = 3, difficulty = 1, max_humans = 1, spawn_ticks = 20 })
for _ = 1, 60 do
	sim:step()
end
expect(sim.map.id == "world@80" and sim.tribe_count == Sim.default_tribes(small), "a Sim on the small build runs")

print(if fails == 0 then "map_scale: all passed" else string.format("map_scale: %d FAILED", fails))
if fails > 0 then
	error("map_scale failed")
end
