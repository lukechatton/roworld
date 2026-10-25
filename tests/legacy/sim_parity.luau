-- sim-core: exact parity with the ORIGINAL on everything that does not depend on the RNG.
-- tests/sim_matches_orig.json was produced by tools/simcore/simcore_probe.gd run with the Airship
-- Editor in a scratch copy of ~/games/airfront (see tools/simcore/README in build/notes/sim-core.md).
-- Run: .bin/lune run tests/sim_matches.luau
require("./prelude")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Defs = require("../src/shared/Core/Defs")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local SimColors = require("../src/shared/Core/SimColors")
local Sim = require("../src/shared/Core/Sim")

local ref = serde.decode("json", fs.readFile("tests/sim_matches_orig.json"))
local fails = 0
local function expect(cond: boolean, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end
local function list_eq(a: { any }, b: { any }): (boolean, number)
	if #a ~= #b then
		return false, -1
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false, i
		end
	end
	return true, 0
end
-- Godot keeps RGBA8 colours in PackedInt32Array (signed): compare modulo 2^32.
local function u32(list: { number }): { number }
	local out = {}
	for i, v in list do
		out[i] = v % 4294967296
	end
	return out
end
ref.nation_colors = u32(ref.nation_colors)
ref.human_palette = u32(ref.human_palette)
ref.tribe_palette = u32(ref.tribe_palette)
ref.human_colors = u32(ref.human_colors)

local map = WorldMap.shared()
local sim = Sim.new(map, { seed = 1, difficulty = 1, tribes = 0, max_humans = 1 })
local cols, tiles, spawn = {}, {}, {}
for id = 1, sim.owner_total do
	table.insert(cols, sim.o_color[id])
	table.insert(tiles, sim.o_tiles[id])
	table.insert(spawn, sim.o_spawn_tile[id])
end
local ok, at = list_eq(spawn, ref.nation_spawn)
expect(ok, "88 nation spawn tiles identical" .. (if ok then "" else " (first diff at " .. at .. ")"))
ok, at = list_eq(tiles, ref.nation_tiles)
expect(ok, "nation start disks identical (tile counts)" .. (if ok then "" else " (first diff at " .. at .. ")"))
local owned = {}
for t = 0, Defs.TILE_COUNT - 1 do
	local o = buffer.readi32(sim.owner, t * 4)
	if o ~= 0 then
		table.insert(owned, t * 1024 + o)
	end
end
ok, at = list_eq(owned, ref.owned)
expect(ok, ("owner grid identical after the nation spawns (%d tiles)"):format(#owned))
local diffc = 0
for i = 1, #cols do
	if cols[i] ~= ref.nation_colors[i] then
		diffc += 1
		print(
			("    colour %s: %s vs original %s"):format(
				sim.o_name[i],
				Defs.rgba_html(cols[i]),
				Defs.rgba_html(ref.nation_colors[i])
			)
		)
	end
end
expect(diffc == 0, "nation colours (authored + OKLab nudges) identical")
local bc = {}
for id = 1, 10 do
	table.insert(bc, sim.bcount[id])
end
expect((list_eq(bc, ref.bcount)), "border list sizes identical")
ok, at = list_eq(SimColors.human_palette(), ref.human_palette)
expect(
	ok,
	("human palette identical (%d colours)"):format(#ref.human_palette) .. (if ok then "" else " diff at " .. at)
)
ok, at = list_eq(SimColors.tribe_palette(), ref.tribe_palette)
expect(ok, "tribe palette identical" .. (if ok then "" else " diff at " .. at))
local lab_ok = true
for i, c in { 0xff0000ff, 0x00ff00ff, 0x3366ccff, 0x719bfaff, 0xffd23fff } do
	local l = SimColors.oklab(c)
	local r = ref.oklab[i]
	if math.abs(l.x - r[1]) > 1e-6 or math.abs(l.y - r[2]) > 1e-6 or math.abs(l.z - r[3]) > 1e-6 then
		lab_ok = false
	end
end
expect(lab_ok, "oklab() matches to 1e-6 (Godot Vector3 is float32)")
local hid = sim:add_human("p", "P")
local hc = {}
for _, t in { 256574, 145 * 1024 + 300, 110 * 1024 + 530, 300 * 1024 + 800 } do
	table.insert(hc, SimColors.for_human(sim, hid, t, 120))
end
expect((list_eq(hc, ref.human_colors)), "human colour picks identical")
-- nav
expect(sim.nav.reg_count == ref.regions, "nav regions " .. ref.regions)
local nav = sim.nav
local ct = map.coast_tiles
local pbad = 0
for i = 0, 39 do
	local a = ct[(i * 7919) % #ct + 1]
	local b = ct[(i * 104729 + 17) % #ct + 1]
	local r = ref.paths[i + 1]
	if r[1] ~= a or r[2] ~= b then
		pbad += 1
		continue
	end
	local body = buffer.readu8(map.coast_body, a)
	if buffer.readu8(map.coast_body, b) ~= body then
		if r[3] ~= -1 then
			pbad += 1
		end
		continue
	end
	local wa = nav:water_next_to(a, body)
	local wb = nav:water_next_to(b, body)
	local p = nav:find_path(wa, wb)
	local mid = if #p > 0 then p[#p // 2 + 1] else -1
	if #p ~= r[3] or wa ~= r[4] or wb ~= r[5] or mid ~= r[6] then
		pbad += 1
		print(("    path %d: %d tiles (orig %d), mid %d (orig %d)"):format(i, #p, r[3], mid, r[6]))
	end
end
expect(pbad == 0, "40 water paths identical (length, endpoints, middle tile)")
local dbad = 0
for i, d in ref.disks do
	-- recompute r exactly like the probe (the JSON round-trip shortens the float)
	local r = 1.5 + (i - 1) * 1.7
	local a1, a2 = #sim:disk_tiles(d[1], r, false), #sim:disk_tiles(d[1], r)
	if a1 ~= d[3] or a2 ~= d[4] then
		dbad += 1
		print(("    disk c=%d r=%.2f: %d/%d vs original %d/%d"):format(d[1], r, a1, a2, d[3], d[4]))
	end
end
expect(dbad == 0, "30 disk_tiles sizes identical")
local rs = {}
for k = 0, 2 do
	for _, tl in { 0, 1, 50, 1000, 30000 } do
		table.insert(rs, Rules.max_troops(k, tl, 2, 1))
		table.insert(rs, Rules.troop_growth(k, 50000.0 + tl, 200000.0, 1))
	end
end
table.insert(rs, Rules.trade_gold(123))
table.insert(rs, Rules.train_spawn_rate(3, 40.0))
table.insert(rs, Rules.trade_spawn_rate(2, 150.0))
table.insert(rs, Rules.sam_range_at(3, 20))
table.insert(rs, Rules.large_territory_bonus(123456.0, 0.7))
table.insert(rs, Rules.warhead_death(300000.0, 1000000.0))
local rbad = 0
for i = 1, #rs do
	if math.abs(rs[i] - ref.rules[i]) > 1e-9 * math.max(1, math.abs(ref.rules[i])) then
		rbad += 1
		print(("    rules[%d] %.12g vs %.12g"):format(i, rs[i], ref.rules[i]))
	end
end
expect(rbad == 0, ("%d Rules formula samples identical (1e-9)"):format(#rs))
local fmts = {
	Defs.format_troops(12345.0),
	Defs.format_troops(1234567.0),
	Defs.format_troops(99999.9),
	Defs.format_troops(-5.5),
	Defs.format_troops(9999999.0),
	Defs.format_troops(12350.0),
}
ok = list_eq(fmts, ref.format)
expect(ok, "format_troops strings identical: " .. table.concat(fmts, " ") .. " | " .. table.concat(ref.format, " "))
print(fails == 0 and "sim_matches ok" or ("sim_matches FAILED " .. fails))
if fails > 0 then
	error("failures")
end
