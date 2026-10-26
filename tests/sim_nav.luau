-- sim-core: SimNav build + path queries on imported maps (flat, no wrap)
-- (run: .bin/lune run tests/sim_nav.luau)
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local WorldMap = require("../src/shared/Core/WorldMap")
local SimNav = require("../src/shared/Core/SimNav")
local Rng = require("../src/shared/Core/Rng")
local fails = 0
local function expect(c, w)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end
local readu16 = buffer.readu16
local readi32 = buffer.readi32

--- Random routes between coastal tiles of `map` on body `body`; checks every path is dense (4/8
--- steps, never across the map edge), on navigable water of that body (a body change is only allowed
--- on a diagonal one-tile strait whose orthogonal corners are land), with exact endpoints.
local function stress(map: any, nav: any, body: number, routes: number, seed: number): (number, number)
	local W = map.W
	local rng = Rng.new(seed)
	local n, bad, total, worst, longest = 0, 0, 0.0, 0.0, 0
	for _ = 1, routes * 20 do
		if n >= routes then
			break
		end
		local a = map:coast_tile(rng:randi() % map.coast_count)
		local b = map:coast_tile(rng:randi() % map.coast_count)
		if map:coast_body_of(a) ~= body or map:coast_body_of(b) ~= body then
			continue
		end
		local wa = nav:water_next_to(a, body)
		local wb = nav:water_next_to(b, body)
		if wa < 0 or wb < 0 then
			continue
		end
		local s = os.clock()
		local p = nav:find_path(wa, wb)
		local dt = (os.clock() - s) * 1000
		total += dt
		worst = math.max(worst, dt)
		n += 1
		longest = math.max(longest, #p)
		if #p == 0 then
			bad += 1
			continue
		end
		for i = 1, #p do
			local t = p[i]
			if t < 0 or t >= map.N or readu16(map.water_body, t * 2) == 0 or readi32(nav.region, t * 4) < 0 then
				bad += 1
				break
			end
			if i > 1 then
				local q = p[i - 1]
				local dx = math.abs(t % W - q % W)
				local dy = math.abs(t // W - q // W)
				if dx > 1 or dy > 1 then
					bad += 1
					break
				end
				if readu16(map.water_body, t * 2) ~= readu16(map.water_body, q * 2) then
					local c1 = (q // W) * W + t % W
					local c2 = (t // W) * W + q % W
					if dx ~= 1 or dy ~= 1 or readi32(nav.region, c1 * 4) >= 0 or readi32(nav.region, c2 * 4) >= 0 then
						bad += 1
						break
					end
				end
			end
		end
		if p[1] ~= wa or p[#p] ~= wb then
			bad += 1
		end
	end
	print(
		("  %s: %d routes on body %d, avg %.2f ms, worst %.2f ms, longest %d tiles"):format(
			map.id,
			n,
			body,
			total / math.max(n, 1),
			worst,
			longest
		)
	)
	return n, bad
end

-- pangaea: one ocean around a supercontinent
local map = WorldMap.get("pangaea")
local t0 = os.clock()
local nav = SimNav.shared(map)
print(("  %s nav build %.0f ms, regions %d"):format(map.id, (os.clock() - t0) * 1000, nav.reg_count))
expect(nav.reg_count > 1000 and nav.W == map.W and nav.CW == math.ceil(map.W / 8), "regions over the map's grid")
local nav2 = SimNav.shared(map)
expect(nav2.region == nav.region and nav2._g ~= nav._g, "shared graph per map, private scratch")
local n, bad = stress(map, nav, 1, 40, 99)
expect(bad == 0 and n >= 30, "random ocean routes found, dense, on water, endpoints exact")

-- a resampled map with lakes (more than one water body; k_lin > 1)
local map2 = WorldMap.get("world@80")
local navb = SimNav.shared(map2)
expect(navb.region ~= nav.region and navb.W == map2.W, "another map gets its own graph (both live at once)")
expect(SimNav.shared(map).region == nav.region, "the first map's graph is still cached")
local n2, bad2 = stress(map2, navb, 1, 30, 7)
expect(bad2 == 0 and n2 >= 20, "routes on the resampled map")
-- different bodies never connect
local lake = -1
for k = 0, map2.coast_count - 1 do
	local c = map2:coast_tile(k)
	if map2:coast_body_of(c) > 1 then
		lake = c
		break
	end
end
if lake >= 0 then
	local wl = navb:water_next_to(lake, map2:coast_body_of(lake))
	local wo = -1
	for k = 0, map2.coast_count - 1 do
		local c = map2:coast_tile(k)
		if map2:coast_body_of(c) == 1 then
			wo = navb:water_next_to(c, 1)
			break
		end
	end
	expect(#navb:find_path(wl, wo) == 0, "no route between different water bodies")
end

-- straight lines never wrap: from the last column to the first they cross the whole map
local W = map.W
local line = {}
SimNav.line_tiles(W, 100 * W + (W - 2), 102 * W + 1, line)
expect(#line == W - 3 + 0 and line[#line] == 102 * W + 1, "line_tiles is flat (" .. #line .. " tiles)")
for i = 2, #line do
	local a, b = line[i - 1], line[i]
	if math.abs(a % W - b % W) > 1 or math.abs(a // W - b // W) > 1 then
		expect(false, "line_tiles dense")
		break
	end
end
local near = {}
SimNav.line_tiles(W, 5 * W + 3, 8 * W + 6, near)
expect(#near == 3 and near[3] == 8 * W + 6, "line_tiles diagonal")

print(fails == 0 and "sim_nav ok" or ("sim_nav FAILED " .. fails))
if fails > 0 then
	error("failures")
end
