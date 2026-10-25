-- Map import round trip (tools/maps/import_maps.py → src/server/MapData, src/shared/Data/Maps,
-- src/shared/Data/MapList): data modules decode (base64 + zstd) to the declared size, sizes and land
-- counts match the full-size map manifests (exactly for maps under the tile budget), resampled maps stay
-- within the budget with k_lin = sqrt(full-size tiles / tiles), nations sit inside the map on land, and
-- the derived WorldMap tables are consistent with the decoded bytes.
-- Run: .bin/lune run tests/maps_import.luau
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local Defs = require("../src/shared/Core/Defs")
local MapCodec = require("../src/shared/Core/MapCodec")
local MapList = require("../src/shared/Data/MapList")
local WorldMap = require("../src/shared/Core/WorldMap")

local BUDGET = 2500000
local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end
local readu8 = buffer.readu8

-- registry
local ids = {}
for _, row in MapList.maps do
	ids[row.id] = true
end
expect(#MapList.maps >= 90, ("registry lists %d maps"):format(#MapList.maps))
expect(MapList.get(MapList.DEFAULT) ~= nil and MapList.get(MapList.DEFAULT).replicated, "default map is replicated")
expect(string.find(MapList.CREDITS, "CC BY%-SA 4.0") ~= nil and MapList.ATTRIBUTION == "OpenFront", "credits")
local over = 0
for _, row in MapList.maps do
	if row.width * row.height > BUDGET or row.k_lin < 1 then
		over += 1
	end
end
expect(over == 0, "every map within the 2.5M tile budget, k_lin >= 1")

for _, id in { "bosphorusstraits", "italia", "world", "japan" } do
	print(id)
	local row = MapList.get(id)
	local data = WorldMap.load_data(id)
	expect(row ~= nil and data ~= nil, "registry row + data module")
	if data == nil or row == nil then
		continue
	end
	expect(data.license == "CC BY-SA 4.0" and data.attribution == "OpenFront", "licence + attribution in the module")
	local t0 = os.clock()
	local bytes = MapCodec.terrain_bytes(data)
	local dt = os.clock() - t0
	expect(
		buffer.len(bytes) == data.width * data.height,
		("decodes to %d bytes (%.0f ms)"):format(buffer.len(bytes), dt * 1000)
	)
	expect(
		row.width == data.width and row.height == data.height and row.land_tiles == data.land_tiles,
		"registry matches"
	)
	local src = data.source
	local land = 0
	local bad = 0
	for i = 0, buffer.len(bytes) - 1 do
		local b = readu8(bytes, i)
		if b >= 128 and b ~= 0x9F then
			land += 1
		end
		-- impassable is exactly 0x9F; water never has bits 7; land magnitudes stay 0..30
		if b >= 128 and b ~= 0x9F and bit32.band(b, 31) > 30 then
			bad += 1
		end
		if b < 128 and bit32.band(b, 31) > 31 then
			bad += 1
		end
	end
	expect(bad == 0, "byte format")
	expect(land == data.land_tiles, "land count = the module's")
	if src.width * src.height <= BUDGET then
		expect(data.width == src.width and data.height == src.height and data.k_lin == 1, "full resolution (unscaled)")
		expect(land == src.land_tiles, ("land %d = manifest map.num_land_tiles"):format(land))
	else
		local k = math.sqrt(src.width * src.height / (data.width * data.height))
		expect(data.width * data.height <= BUDGET, "resampled within the budget")
		expect(math.abs(data.k_lin - k) < 1e-4, ("k_lin %.3f = sqrt(source / tiles)"):format(data.k_lin))
		local expect_land = src.land_tiles / (k * k)
		expect(
			math.abs(land - expect_land) / expect_land < 0.05,
			("land %d ~ manifest %d / k^2"):format(land, src.land_tiles)
		)
	end
	-- WorldMap from the data
	local map = WorldMap.get(id)
	expect(map.W == data.width and map.H == data.height and map.k_lin == data.k_lin, "WorldMap size / scale")
	expect(buffer.tostring(map.tile_bytes) == buffer.tostring(bytes), "map.tile_bytes = the decoded bytes")
	expect(map.land_count == land, "land_count")
	local W, N = map.W, map.N
	local coast_ok = true
	for k = 0, map.coast_count - 1 do
		local c = map:coast_tile(k)
		local x = c % W
		local wet = (x > 0 and readu8(map.tile_bytes, c - 1) < 128)
			or (x < W - 1 and readu8(map.tile_bytes, c + 1) < 128)
			or (c >= W and readu8(map.tile_bytes, c - W) < 128)
			or (c < N - W and readu8(map.tile_bytes, c + W) < 128)
		-- the tile bytes' shoreline bit agrees with our coast table
		if not wet or bit32.band(readu8(map.tile_bytes, c), 0x40) == 0 or map:coast_body_of(c) == 0 then
			coast_ok = false
			break
		end
	end
	expect(coast_ok, ("%d coastal tiles = shoreline land next to water"):format(map.coast_count))
	local on_land, placed = 0, 0
	for _, nd in map.nations do
		if nd.tile >= 0 then
			placed += 1
			expect(nd.x >= 0 and nd.x < W and nd.y >= 0 and nd.y < map.H, "nation " .. nd.name .. " inside the map")
			if map:is_contestable(nd.tile) then
				on_land += 1
			end
		end
	end
	expect(placed == 0 or on_land >= placed * 0.9, ("%d/%d nations on land"):format(on_land, placed))
	expect(#map.nations == row.nations, "nation count = registry")
	print(
		("  %dx%d k_lin %.3f land %d coast %d water bodies %d nations %d"):format(
			W,
			map.H,
			map.k_lin,
			map.land_count,
			map.coast_count,
			map.water_body_count,
			#map.nations
		)
	)
	if id ~= MapList.DEFAULT then
		WorldMap.release(id)
	end
end

-- terrain codes follow the magnitude bands (plains < 10 <= highland < 20 <= mountain)
local m = WorldMap.get("japan")
local ok = true
for i = 0, m.N - 1, 7 do
	local b = readu8(m.tile_bytes, i)
	local t = readu8(m.terrain, i)
	if b >= 128 and b ~= 0x9F then
		local mag = bit32.band(b, 31)
		local want = if mag < 10 then Defs.T_PLAINS elseif mag < 20 then Defs.T_HIGHLAND else Defs.T_MOUNTAIN
		if t ~= want then
			ok = false
		end
	end
end
expect(ok, "terrain classes")

print(fails == 0 and "maps_import ok" or ("maps_import FAILED " .. fails))
if fails > 0 then
	error("failures")
end
