-- sim-core: basic unit tests for Defs / Rng / WorldMap / Rules (run: .bin/lune run tests/sim_core_basics.luau)
-- Maps are flat (no wrap): pangaea (1000x1000, k_lin 1) and a budget-resampled one.
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local MapList = require("../src/shared/Data/MapList")
local Ev = require("../src/shared/Core/Ev")
local Rng = require("../src/shared/Core/Rng")
local WorldMap = require("../src/shared/Core/WorldMap")
local Rules = require("../src/shared/Core/Rules")

local fails = 0
local function expect(cond: boolean, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end
local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-9)
end

-- Defs helpers
expect(Defs.trunc(-3.7) == -3 and Defs.trunc(3.7) == 3, "trunc")
expect(Defs.idiv(-7, 2) == -3 and Defs.idiv(7, 2) == 3, "idiv truncates")
expect(Defs.imod(-7, 3) == -1 and Defs.posmod(-7, 3) == 2, "imod / posmod")
expect(Defs.round(2.5) == 3 and Defs.round(-2.5) == -3, "round half away")
expect(Defs.smoothstep(0, 1, 0.5) == 0.5 and Defs.smoothstep(0, 1, -1) == 0, "smoothstep")
expect(
	Defs.struct_kind_from_name("sam") == Defs.S_SAM and Defs.struct_kind_from_name("x") == -1,
	"struct_kind_from_name"
)
expect(
	Defs.STRUCT_NAMES[Defs.S_CITY] == "city" and Defs.NUKE_NAMES[Defs.N_MIRV] == "mirv",
	"enum tables keyed by enum value"
)
local la, lo2 = Defs.xyz_latlon(Defs.latlon_xyz(38.9, -77.01))
expect(near(la, 38.9, 1e-9) and near(lo2, -77.01, 1e-9), "latlon_xyz / xyz_latlon round trip (camera math)")
expect(Defs.tile_latlon == nil and Defs.row_cos == nil and Defs.ROW_COS == nil, "no globe grid helpers left")
expect(
	Defs.format_troops(12345) == "12.3K"
		and Defs.format_troops(1234567) == "1.23M"
		and Defs.format_troops(-850.7) == "-850"
		and Defs.format_troops(123456) == "123K"
		and Defs.format_troops(12345678) == "12.3M",
	"format_troops"
)
expect(Defs.html_rgba("#ffd23f") == 0xffd23fff, "html_rgba")
local r, g, b, a = Defs.rgba_bytes(0x12345678)
expect(r == 0x12 and g == 0x34 and b == 0x56 and a == 0x78, "rgba_bytes")
expect(Defs.hsv_rgba(0, 1, 1) == 0xff0000ff and Defs.hsv_rgba(1 / 3, 1, 1) == 0x00ff00ff, "hsv_rgba")
expect(Ev.SAM_LAUNCH == 29 and Ev.OWNER_ADD == 0, "Ev ids")

-- Rng
local r1 = Rng.new(1)
local r2 = Rng.new(1)
local same = true
for _ = 1, 1000 do
	if r1:randi() ~= r2:randi() then
		same = false
	end
end
expect(same, "Rng deterministic")
local rr = Rng.new(42)
local hist = table.create(8, 0)
local lo, hi = 1e18, -1e18
local fsum = 0
for _ = 1, 80000 do
	local v = rr:randi()
	hist[(v % 8) + 1] += 1
	lo = math.min(lo, v)
	hi = math.max(hi, v)
	fsum += rr:randf()
end
local okh = true
for i = 1, 8 do
	if math.abs(hist[i] - 10000) > 500 then
		okh = false
	end
end
expect(okh and lo >= 0 and hi < 2 ^ 32 and hi > 2 ^ 31, "Rng low bits uniform, range uint32")
expect(math.abs(fsum / 80000 - 0.5) < 0.01, "randf mean")
local rmin, rmax = 99, -99
for _ = 1, 2000 do
	local v = rr:randi_range(-3, 3)
	rmin = math.min(rmin, v)
	rmax = math.max(rmax, v)
end
expect(rmin == -3 and rmax == 3, "randi_range inclusive")
expect(Rng.new(1):randi() ~= Rng.new(2):randi(), "different seeds differ")

-- WorldMap (pangaea: 1000 x 1000, 308,767 land tiles in its manifest)
local t0 = os.clock()
local map = WorldMap.get("pangaea")
print(
	("  map load %.0f ms, contestable %d, coast %d, water bodies %d"):format(
		(os.clock() - t0) * 1000,
		map.contestable_count,
		map.coast_count,
		map.water_body_count
	)
)
expect(map.W == 1000 and map.H == 1000 and map.N == 1000000 and map.k_lin == 1 and map.k_area == 1, "size / scale")
expect(WorldMap.get("pangaea") == map, "one shared instance per id")
expect(map.contestable_count == 308767 and map.land_count == 308767, "land count matches the manifest")
local first_land = map:land_tile(0)
expect(first_land >= 0 and map:is_contestable(first_land), "land_list holds 0-based land tiles")
local c = map:coast_tile(0)
expect(map:is_coastal(c) and map:coast_body_of(c) > 0, "coast tiles know their water body")
local W = map.W
expect(#map:neighbors4(0) == 2 and map:neighbors4(0)[1] == 1, "neighbors4: no wrap at the corner")
expect(
	map:neighbor(W, 0) == -1 and map:neighbor(W - 1, 1) == -1 and map:neighbor(5, 2) == -1,
	"neighbor() stops at edges"
)
expect(map:neighbor(W + 5, 0) == W + 4 and map:neighbor(W + 5, 3) == 2 * W + 5, "neighbor() inside")
expect(map.dist2(0, W - 1) == (W - 1) ^ 2, "dist2: no wrap")
expect(map.range_d2(3 * W + 4, 7 * W + 1) == 25, "range_d2 = euclideanDistSquared")
expect(map.geo_manhattan(3 * W + 4, 7 * W + 1) == 7, "geo_manhattan = manhattanDist")
expect(near(map.gc_dist(3 * W + 4, 7 * W + 1), 5), "gc_dist = euclidean")
expect(map.geo_span(0, 7.2) == 8, "geo_span = ceil(r)")
-- terrain codes from the source byte
local counts = table.create(7, 0)
for i = 0, map.N - 1 do
	local b = buffer.readu8(map.tile_bytes, i)
	local tt = buffer.readu8(map.terrain, i)
	counts[tt + 1] += 1
	if b < 128 then
		assert(tt == (if bit32.band(b, 0x20) ~= 0 then Defs.T_OCEAN else Defs.T_LAKE))
		assert(map:body_of(i) > 0 and buffer.readu8(map.land, i) == 0)
	elseif b == 0x9F then
		assert(tt == Defs.T_ICECAP and buffer.readu8(map.land, i) == 0)
	else
		local m = bit32.band(b, 31)
		assert(tt == (if m < 10 then Defs.T_PLAINS elseif m < 20 then Defs.T_HIGHLAND else Defs.T_MOUNTAIN))
		assert(buffer.readu8(map.land, i) == 1 and map:body_of(i) == 0)
	end
end
expect(
	true,
	("terrain codes from tile_bytes (ocean %d lake %d plains %d highland %d mountain %d)"):format(
		counts[1],
		counts[2],
		counts[3],
		counts[4],
		counts[5]
	)
)
local ocean_seen = false
for i = 0, map.N - 1, 997 do
	if buffer.readu8(map.terrain, i) == Defs.T_OCEAN then
		ocean_seen = true
		expect(map:body_of(i) == 1, "the ocean is water body 1")
		break
	end
end
expect(ocean_seen, "found ocean")
expect(#map.nations == 29 and map.nations[1].tile == map.nations[1].y * W + map.nations[1].x, "manifest nations")
expect(#WorldMap.load_tribe_names() >= 400, "tribe names")
-- the registry
expect(
	MapList.DEFAULT == "world" and MapList.get("world") ~= nil and MapList.get("world").replicated == true,
	"MapList default"
)
expect(
	#MapList.maps >= 1 and MapList.LICENSE == "Public domain",
	"MapList: our own maps"
)
-- every registered map loads, with its listed size and nations, each nation standing on land
for _, row in MapList.maps do
	local m = WorldMap.get(row.id)
	local on_land = 0
	for _, n in m.nations do
		if n.tile ~= nil and m:is_land(n.tile) then
			on_land += 1
		end
	end
	expect(
		m.W == row.width and m.H == row.height and #m.nations == row.nations and on_land == row.nations,
		("map %s: %dx%d, %d nations on land"):format(row.id, m.W, m.H, on_land)
	)
end
-- a resampled map carries its scale (World at 80%, the public matches' size)
local big = WorldMap.get("world@80")
expect(
	big.N < WorldMap.get("world").N and big.k_lin > 1 and near(big.k_area, big.k_lin ^ 2),
	"resampled map: fewer tiles, k_lin > 1"
)
local Rb = Rules.for_map(big)
expect(
	Rb ~= Rules and Rb.K_LIN == big.k_lin and near(Rb.sam_range(1), 70 / big.k_lin),
	"Rules.for_map scales distances"
)
expect(Rules.for_map(map) == Rules and Rules.for_k(big.k_lin) == Rb, "rules cached per scale; k_lin 1 = full size")

-- Rules numbers
expect(
	Rules.build_cost("city", 0) == 125000
		and Rules.build_cost("port", 3) == 1000000
		and Rules.build_cost("factory", 2) == 500000,
	"city/port/factory cost"
)
expect(Rules.build_cost("defense", 0) == 50000 and Rules.build_cost("defense", 9) == 250000, "defense cost")
expect(
	Rules.build_cost("sam", 1) == 3000000
		and Rules.build_cost("silo", 5) == 1000000
		and Rules.build_cost("warship", 1) == 500000,
	"sam/silo/warship cost"
)
expect(Rules.build_cost("nope", 0) == -1, "unknown kind")
expect(
	Rules.nuke_cost("mirv", 2) == 55000000 and Rules.nuke_cost("atom") == 750000 and Rules.nuke_cost("warhead") == -1,
	"nuke_cost"
)
expect(Rules.K_LIN == 1 and Rules.K_AREA == 1, "module rules are full size (k_lin 1)")
local inner, outer = Rules.nuke_radii(Defs.N_ATOM)
expect(near(inner, 12) and near(outer, 30), "nuke_radii atom")
local _, mo = Rules.nuke_radii(Defs.N_MIRV)
expect(mo == 1500, "nuke_radii mirv spread 1500")
expect(near(Rules.sam_range(1), 70 / Rules.K_LIN) and near(Rules.sam_range(5), (150 - 48) / Rules.K_LIN), "sam_range")
expect(
	near(Rules.sam_range_at(2, 0), Rules.sam_range(1)) and near(Rules.sam_range_at(2, 45), Rules.sam_range(2)),
	"sam_range_at"
)
expect(
	Rules.TRUCK_TPT_X100 == 50 and Rules.TRANSPORT_TPT_X100 == 100 and Rules.WARSHIP_HUNT_TPT_X100 == 50,
	"tpt constants"
)
expect(
	Rules.WARSHIP_RANGE == 130 and Rules.WARSHIP_PATROL_RADIUS == 100 and Rules.MIRV_SPREAD == 1500,
	"int range constants"
)
expect(Rules.STRUCT_MIN_DIST == 15 and Rules.DEFENSE_RADIUS == 30 and Rules.SPAWN_RADIUS == 4, "structure distances")
expect(Rules.warship_max_hp(1) == 1200 and Rules.warship_max_hp(9) == 1600, "warship_max_hp")
expect(
	Rules.shell_damage(1, 0) == 200 and Rules.shell_damage(5, 0) == 300 and Rules.shell_damage(3, 2) == 350,
	"shell_damage"
)
expect(Rules.shell_flight_ticks(0) == 1 and Rules.shell_flight_ticks(10) == 4, "shell_flight_ticks")
expect(Rules.nuke_flight_ticks(100, Defs.N_ATOM) == 10, "nuke_flight_ticks")
expect(Rules.human_grace_ticks(0) == 3000 and Rules.human_grace_ticks(9) == 1200, "human_grace_ticks")
expect(
	near(Rules.max_troops(Defs.KIND_HUMAN, 0, 0, 1), 100000)
		and near(Rules.max_troops(Defs.KIND_TRIBE, 0, 0, 1), 100000 / 3),
	"max_troops base"
)
local mt = Rules.max_troops(Defs.KIND_NATION, 1000, 2, 1)
expect(near(mt, (2 * ((1000 * Rules.K_AREA) ^ 0.6 * 1000 + 50000) + 500000) * 0.75, 1e-6), "max_troops nation")
local grow = Rules.troop_growth(Defs.KIND_HUMAN, 25000, 100000, 1)
expect(near(grow, (10 + 25000 ^ 0.73 / 4) * 0.75, 1e-9), "troop_growth")
expect(Rules.troop_growth(Defs.KIND_HUMAN, 200000, 100000, 1) == -100000, "troop_growth snaps to cap")
expect(Rules.NATION_GROWTH_MULT[0] == 0.9, "nation growth multipliers are exact doubles")
expect(Rules.train_spawn_rate(1, 0) == math.floor(165 / Rules.train_saturation(0)), "train_spawn_rate")
expect(Rules.trade_spawn_rate(0, 0) == math.floor(100 / Rules.trade_saturation(0)), "trade_spawn_rate")
expect(near(Rules.trade_gold(0), 75000 / (1 + math.exp(9))), "trade_gold")
expect(
	Rules.train_gold("self", 0) == 10000 and Rules.train_gold("ally", 12) == 20000 and Rules.train_gold("x", 40) == 5000,
	"train_gold"
)
expect(
	Rules.passive_income(Defs.KIND_TRIBE, 5) == 500 and Rules.passive_income(Defs.KIND_HUMAN, 0) == 0,
	"passive_income"
)
expect(near(Rules.large_territory_bonus(300000, 0.7), 0.65), "large_territory_bonus midpoint")

print(fails == 0 and "sim_core_basics ok" or ("sim_core_basics FAILED " .. fails))
if fails > 0 then
	error("failures")
end
