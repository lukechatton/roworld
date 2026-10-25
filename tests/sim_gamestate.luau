-- sim-core: GameState unit test with a synthetic snapshot + deltas (run: .bin/lune run tests/sim_gamestate.luau)
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local Rules = require("../src/shared/Core/Rules")
local GameState = require("../src/shared/Core/GameState")
local WorldMap = require("../src/shared/Core/WorldMap")

local fails = 0
local function expect(cond: boolean, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

-- A non-default, non-1024-wide map (pangaea, 1000 x 1000).
local map = WorldMap.get("pangaea")
local N = map.N
local W = map.W
local grid = buffer.create(N * 4)
local flags = buffer.create(N)
-- owner 1 holds a 5x5 block around (292, 145), owner 2 one around (520, 110)
local us = 145 * W + 292
local eu = 110 * W + 520
for dy = -2, 2 do
	for dx = -2, 2 do
		buffer.writei32(grid, (us + dy * W + dx) * 4, 1)
		buffer.writei32(grid, (eu + dy * W + dx) * 4, 2)
	end
end
buffer.writeu8(flags, 1000, 1)
local snap = {
	map_id = "pangaea",
	map_w = W,
	map_h = map.H,
	t = 100,
	phase = Defs.PHASE_PLAYING,
	phase_left = 0,
	time_limit_ticks = 0,
	playing_since = 50,
	mirvs_launched = 0,
	winner = 0,
	over_reason = -1,
	owner = grid,
	flags = flags,
	built = { { 1, 1, 0, 0, 0, 0, 0, 0, 0 } },
	owners = {
		{ 1, "United States", 0x719bfaff, Defs.KIND_NATION, 0, true, 25, 1000, 5000, 200000, 1000, 0, us },
		{ 2, "France", 0xff0000ff, Defs.KIND_HUMAN, 0, true, 25, 2000, 9000, 300000, 1000, 0, eu },
	},
	structs = { { 7, Defs.S_CITY, 1, us, 1, 60 } },
	roads = {},
	units = { { 3, Defs.U_TRANSPORT, 1, { us + 10, us + 11, us + 12 }, 90, 195, 500, 0, 0, 0, 0, -1 } },
	nukes = {},
	shells = {},
	sam_missiles = {},
	attacks = { { 4, 1, 2, 800, eu } },
	allies = {},
	requests = { { 2, 1 } },
}
local gs = GameState.new(map)
expect(gs.map == map and gs.W == W and gs.N == N and buffer.len(gs.owner) == N * 4, "GameState on the map's grid")
expect(gs.rules == Rules.for_map(map), "state.rules = Rules.for_map(map)")
local loaded = 0
gs.snapshot_loaded:Connect(function()
	loaded += 1
end)
gs:load_snapshot(snap)
gs.local_owner = 2
expect(loaded == 1 and gs.loaded, "snapshot_loaded fired")
expect(gs:tile_owner(us) == 1 and gs:owner_of(eu) == 2 and gs:tile_owner(-1) == 0, "owner grid")
expect(gs.owners[1].tiles == 25 and gs.owners[2].tiles == 25, "tiles recounted")
expect(gs.fallout_count == 1 and gs:has_fallout(1000), "fallout counted")
expect(
	gs:owner_name(0) == "Unclaimed land" and gs:owner_name(1) == "United States" and gs:owner_name(99) == "Unknown",
	"owner_name"
)
expect(gs.owners[1].rgba == 0x719bfaff and typeof(gs.owners[1].color) == "Color3", "owner colour")
expect(gs:label_tile(1) == us, "label_tile = centroid tile")
expect(
	gs:struct_level_sum(1, Defs.S_CITY) == 1 and gs:built_count(1, Defs.S_CITY) == 1 and gs:built_count(3, 0) == 0,
	"struct_level_sum / built_count"
)
expect(Rules.cost_of(gs, 1, "city") == 250000, "Rules.cost_of from GameState")
expect(gs:has_request(2, 1) and not gs:has_request(1, 2), "requests")
expect(gs.attacks[4].troops == 800 and gs:count_units(1, Defs.U_TRANSPORT) == 1, "attacks / units")
local p, f, prog = gs:unit_pose(gs.units[3], 90 + 1.95 / 2)
local ex = Vector3.new(292 + 10 + 1.0, 145 + 0.5, 0) -- halfway between the centres of x 302 and 303
expect(
	(p - ex).Magnitude < 1e-4 and prog > 0.2 and prog < 0.3 and (f - Vector3.new(1, 0, 0)).Magnitude < 1e-9,
	"unit_pose halfway along the first segment (map space)"
)
local tx, ty = gs:tile_xy(us)
expect(tx == 292.5 and ty == 145.5 and gs:tile_dir(us) == Vector3.new(292.5, 145.5, 0), "tile_xy / tile_dir")

-- deltas
local changed = nil
gs.tiles_changed:Connect(function(t)
	changed = t
end)
local got = {}
for _, name in GameState.SIGNAL_NAMES do
	gs[name]:Connect(function(...)
		got[name] = { ... }
	end)
end
local placement = Rules.placement(gs, 1, "city", us + 2)
expect(
	placement.upgrade_sid == 7 and placement.tile == us and placement.reason == "gold" and not placement.ok,
	"placement: upgrade near own finished city (no gold)"
)
gs.owners[1].gold = 10000000
local pl2 = Rules.placement(gs, 1, "factory", us)
expect(pl2.reason == "no_room", "placement: 5x5 blob has no room for a 2nd structure (" .. pl2.reason .. ")")
gs:apply_delta({
	t = 101,
	tiles = { (us + 3) * 1024 + 1, eu * 1024 + 1 },
	flags = { 1000 * 256 + 0 },
	stats = { 1, 26, 1234, 777, 200001, 1500 },
	ev = {
		{ Ev.STRUCT_ADD, 8, Defs.S_PORT, 1, us + 1 },
		{ Ev.STRUCT_LEVEL, 7, 2, 101 },
		{ Ev.UNIT_ADD, 9, Defs.U_WARSHIP, 1, { us + 20 }, 101, 195, 0 },
		{ Ev.SHELL, 1, 0, 9, us + 20, 3, 101, 101, 250 },
		{ Ev.UNIT_DEL, 3, Defs.DEL_DESTROYED },
		{ Ev.NUKE, 11, Defs.N_MIRV, 1, us, eu, 101, 40 },
		{ Ev.ALLY, 1, 2 },
		{ Ev.MSG, 2, Defs.MSG_INFO, "hello" },
		{ Ev.MSG, 1, Defs.MSG_INFO, "not for me" },
		{ Ev.PHASE, Defs.PHASE_PLAYING, 0 },
		{ Ev.ATTACK_END, 4 },
	},
})
expect(gs.tick == 101 and changed ~= nil and #changed == 2, "tiles_changed fired with the packed array")
expect(
	gs:tile_owner(us + 3) == 1 and gs:tile_owner(eu) == 1 and gs.owners[1].tiles == 26 + 1 and gs.owners[2].tiles == 24,
	"tile counts follow deltas"
)
expect(gs.fallout_count == 0 and not gs:has_fallout(1000), "flags delta clears fallout")
expect(gs.owners[1].troops == 1234 and gs.owners[1].gold == 777 and gs.owners[1].income == 1500, "stats rows")
expect(gs.structures[8] ~= nil and gs:built_count(1, Defs.S_PORT) == 1, "STRUCT_ADD counts built")
expect(gs.structures[7].level == 2 and gs:built_count(1, Defs.S_CITY) == 2, "STRUCT_LEVEL raises built count")
expect(gs:built_count(1, Rules.BUILT_WARSHIP) == 1, "warship UNIT_ADD counts built")
expect(
	got.shell_impact ~= nil and got.shell_impact[1] == 1 and got.shell_impact[2] == true,
	"shell impact: target destroyed that tick counts as a hit"
)
expect(gs.units[3] == nil and got.unit_removed[1] == 3, "UNIT_DEL")
expect(gs.mirvs_launched == 1 and gs.nukes[11] ~= nil, "NUKE counts MIRVs")
expect(gs:are_allies(1, 2) and gs:are_allies(2, 1) and not gs:has_request(2, 1), "ALLY clears requests")
expect(got.message ~= nil and got.message[3] == "hello", "MSG only for the local owner")
expect(gs.attacks[4] == nil and got.attack_ended[1] == 4, "ATTACK_END")
local np, nt = gs:nuke_pose(gs.nukes[11], 121)
expect(nt == 0.5 and np.Z > 4.0, "nuke_pose arcs above the map")
gs:apply_delta({
	t = 102,
	tiles = {},
	flags = {},
	ev = { { Ev.BOOM, 11, Defs.N_MIRV, eu, -1, 1 }, { Ev.GAME_OVER, 1, Defs.OVER_DOMINATION } },
})
expect(gs.nukes[11] == nil and gs.phase == Defs.PHASE_OVER and gs.winner == 1, "BOOM / GAME_OVER")
local rank = gs:ranking()
expect(#rank == 2 and rank[1].id == 1, "ranking")

print(fails == 0 and "sim_gamestate ok" or ("sim_gamestate FAILED " .. fails))
if fails > 0 then
	error("failures")
end
