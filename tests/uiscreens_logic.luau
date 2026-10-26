-- ui-screens: headless tests of UICtx / UIRules / BorderTracker / UIInteract against the real
-- GameState + Rules (run: .bin/lune run tests/uiscreens_logic.luau).
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local GameState = require("../src/shared/Core/GameState")
local WorldMap = require("../src/shared/Core/WorldMap")
local Places = require("./world_places")
local Signal = require("../src/shared/Core/Signal")
local UICtx = require("../src/client/UI/UICtx")
local UIRules = require("../src/client/UI/UIRules")
local UIInteract = require("../src/client/UI/UIInteract")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local map = WorldMap.shared()
local W = Defs.W
local N = Defs.TILE_COUNT
local ME = 239
local ENEMY = 5
local FAR = 7

-- ---------------------------------------------------------------------------------------------
-- A small world: my blob on the Polish Baltic coast, an enemy blob touching it to the south,
-- a far owner in Sweden (reachable across the Baltic), neutral land around.
-- ---------------------------------------------------------------------------------------------
local grid = buffer.create(N * 4)
local flags = buffer.create(N)
local function block(center: number, r: number, id: number)
	local cx, cy = center % W, center // W
	for dy = -r, r do
		for dx = -r, r do
			local t = (cy + dy) * W + (cx + dx) % W
			if map:is_contestable(t) then
				buffer.writei32(grid, t * 4, id)
			end
		end
	end
end
-- Gdansk: snapped to the nearest coastal tile (the World grid is finer than the old
-- Earth's, and the home block must reach the Baltic for the boat / coast checks)
local gdansk = Places.latlon_to_tile(54.0, 18.4)
do
	local gx, gy = gdansk % W, gdansk // W
	local best, best_d = gdansk, math.huge
	for dy = -20, 20 do
		for dx = -20, 20 do
			local t = (gy + dy) * W + gx + dx
			local d = dx * dx + dy * dy
			if d < best_d and map:is_coastal(t) then
				best, best_d = t, d
			end
		end
	end
	gdansk = best
end
local south = gdansk + 12 * W
-- (the east coast near Västervik: the block must reach the Baltic; inland, as before 2026-10-26, it
-- missed the coast of the World map made from Natural Earth)
local sweden = Places.latlon_to_tile(57.9, 16.3)
block(gdansk, 5, ME)
block(south, 6, ENEMY)
block(sweden, 4, FAR)
local my_tiles, en_tiles, far_tiles = 0, 0, 0
for t = 0, N - 1 do
	local o = buffer.readi32(grid, t * 4)
	if o == ME then
		my_tiles += 1
	elseif o == ENEMY then
		en_tiles += 1
	elseif o == FAR then
		far_tiles += 1
	end
end
print("tiles me/enemy/far", my_tiles, en_tiles, far_tiles)

local snap = {
	t = 1000,
	phase = Defs.PHASE_PLAYING,
	phase_left = 0,
	time_limit_ticks = 0,
	playing_since = 500,
	mirvs_launched = 0,
	winner = 0,
	over_reason = -1,
	owner = grid,
	flags = flags,
	built = {},
	owners = {
		{ ME, "Luke", 0x719bfaff, Defs.KIND_HUMAN, 0, true, my_tiles, 100000, 2000000, 300000, 1000, 0, gdansk },
		{ ENEMY, "Poland", 0xff4040ff, Defs.KIND_NATION, 0, true, en_tiles, 50000, 10000, 300000, 1000, 0, south },
		{ FAR, "Sweden", 0x40ff40ff, Defs.KIND_NATION, 0, true, far_tiles, 30000, 10000, 300000, 1000, 0, sweden },
	},
	structs = {},
	roads = {},
	units = {},
	nukes = {},
	shells = {},
	sam_missiles = {},
	attacks = {},
	allies = {},
	requests = {},
}
local gs = GameState.new(map)
gs:load_snapshot(snap)
gs.local_owner = ME

-- ---------------------------------------------------------------------------------------------
-- Stand-ins (same surfaces as Session / WorldView / kit components)
-- ---------------------------------------------------------------------------------------------
local session = { mode = UICtx.MODE_SOLO, state = gs, lobby = {}, intents = {} }
function session.send_intent(self: any, intent: any)
	table.insert(self.intents, intent)
end
local PX = 4 -- world: tile (x, y) is drawn at (x*4+2, y*4+2)
local world = { calls = {} }
function world.tile_at_screen(_self: any, p: Vector2): number
	local x, y = math.floor(p.X / PX), math.floor(p.Y / PX)
	if x < 0 or x >= W or y < 0 or y >= Defs.H then
		return -1
	end
	return y * W + x
end
function world.screen_pos_of_tile(_self: any, t: number): Vector2
	return Vector2.new((t % W) * PX + 2, (t // W) * PX + 2)
end
for _, m in
	{
		"set_hover_owner",
		"set_spawn_preview",
		"set_aim",
		"set_range_mode",
		"set_selected_owner",
		"set_range_focus",
		"set_range_owner",
		"focus_tile",
		"set_selected_unit",
	}
do
	world[m] = function(self: any, ...)
		table.insert(self.calls, { m, ... })
	end
end
function world.aim_sams(_self: any): number
	return 0
end

local ctx = UICtx.new()
ctx.session = session
ctx.world = world
ctx.state = gs
ctx.state_mode = UICtx.MODE_SOLO
ctx.borders:bind(gs, ME)
ctx.rules:recount()

local Place = { FOLLOW = 0, ANCHOR = 1, PINNED = 2 }
local tooltip = { Place = Place, place = Place.FOLLOW, shown = false, last = nil }
function tooltip.is_shown(self: any)
	return self.shown
end
function tooltip.hide_tip(self: any)
	self.shown = false
end
function tooltip.show_follow(self: any, spec: any)
	self.shown = true
	self.place = Place.FOLLOW
	self.last = spec
end
function tooltip.show_pinned(self: any, spec: any, _r: any)
	self.shown = true
	self.place = Place.PINNED
	self.last = spec
end
function tooltip.target_rect(_self: any)
	return Rect.new(0, 0, 10, 10)
end
local radial = { is_open = false, center = Vector2.zero, opened = nil }
function radial.close(self: any)
	self.is_open = false
end
function radial.open_at(self: any, tile: number, pos: Vector2, items: any, title: string, col: any)
	self.is_open = true
	self.opened = { tile = tile, pos = pos, items = items, title = title, col = col }
end
local bar = { placing = "", denied = {} }
function bar.button(_self: any, kind: string)
	return {
		deny = function()
			table.insert(bar.denied, kind)
		end,
	}
end
function bar.set_placing(self: any, k: string)
	self.placing = k
end
function bar.is_visible_in_tree(_self: any)
	return true
end
function bar.top_edge(_self: any)
	return 820
end
local target_card = { is_open = false, tile = -1, kind = "", owner_id = 0, shown = 0 }
function target_card.show_target(self: any, t: number, k: string, _act: any)
	self.is_open = true
	self.tile = t
	self.kind = k
	self.owner_id = gs:tile_owner(t)
	self.shown += 1
end
function target_card.hide_card(self: any)
	self.is_open = false
end
function target_card.matches(self: any, t: number, k: string)
	return self.is_open and k == self.kind and gs:tile_owner(t) == self.owner_id
end
local place_confirm = { open = false }
function place_confirm.show_for(self: any, t: number, caption: string, danger: boolean, ok: boolean)
	self.open = true
	self.tile = t
	self.caption = caption
	self.ok = ok
end
function place_confirm.hide_confirm(self: any)
	self.open = false
end
local unit_card = { is_open = false, own = false, uid = 0 }

local inter = UIInteract.new(ctx)
inter.bar = bar
inter.tooltip = tooltip
inter.radial = radial
inter.target_card = target_card
inter.place_confirm = place_confirm
inter.unit_card = unit_card
inter.ui = {
	debug_touch = -1,
	screen = function()
		return "play"
	end,
}
inter.enabled = true
local floats = {}
inter._float = function(_self: any, text: string, icon: string, _col: any, _pos: any)
	table.insert(floats, { text = text, icon = icon })
end
local function last_float(): string
	return if #floats > 0 then floats[#floats].text else ""
end

local function click(t: number)
	ctx.debug_mouse = world:screen_pos_of_tile(t)
	inter._last_click_msec = -100000
	ctx.rules:invalidate()
	inter:on_click(t)
end

-- ---------------------------------------------------------------------------------------------
-- BorderTracker
-- ---------------------------------------------------------------------------------------------
local bt = ctx.borders
local nb = 0
for _ in bt.border do
	nb += 1
end
expect(nb > 0 and nb < my_tiles, "border tiles tracked (" .. nb .. ")")
expect(bt:borders_owner(ENEMY), "borders the enemy")
expect(not bt:borders_owner(FAR), "does not border Sweden by land")
expect(bt:borders_owner(0), "touches neutral land")
expect(bt:has_coast(), "has a coast")
local ids = bt:neighbour_ids()
expect(#ids == 1 and ids[1] == ENEMY, "neighbour ids = {enemy}")
-- a Swedish coastal tile reachable by sea
local swe_coast = -1
for t = 0, N - 1 do
	if buffer.readi32(grid, t * 4) == FAR and map:is_coastal(t) and bt:can_reach_by_sea(t) then
		swe_coast = t
		break
	end
end
expect(swe_coast >= 0, "a Swedish coast is reachable by sea")

-- ---------------------------------------------------------------------------------------------
-- UIRules.primary
-- ---------------------------------------------------------------------------------------------
local function find_tile(pred: (number) -> boolean): number
	for t = 0, N - 1 do
		if pred(t) then
			return t
		end
	end
	return -1
end
local neutral_adj = find_tile(function(t)
	return gs:tile_owner(t) == 0 and map:is_contestable(t) and gs:borders_tile(ME, t)
end)
local enemy_adj = find_tile(function(t)
	return gs:tile_owner(t) == ENEMY and gs:borders_tile(ME, t)
end)
local my_tile = gdansk
local p = ctx.rules:primary(neutral_adj)
expect(
	p.type == "expand" and p.ok and math.abs(p.troops - 25000) < 1, -- the Attack bar's default stop, 25 %
	"primary: expand next to me (" .. tostring(p.type) .. ")"
)
p = ctx.rules:primary(enemy_adj)
expect(p.type == "attack" and p.ok and p.target == ENEMY, "primary: attack a neighbour")
p = ctx.rules:primary(swe_coast)
expect(
	p.type == "boat" and p.ok,
	"primary: boat across the sea (" .. tostring(p.type) .. " " .. tostring(p.reason) .. ")"
)
p = ctx.rules:primary(my_tile)
expect(p.type == "inspect" and p.ok, "primary: own land = inspect")
local ocean = Places.latlon_to_tile(56.0, 5.0)
p = ctx.rules:primary(ocean)
expect(p.type == "none", "primary: ocean = none")
expect(
	ctx.rules:confirm_text({ type = "attack", troops = 24500, target = ENEMY }) == "Attacking Poland with 2.45K",
	"confirm_text"
)

-- ---------------------------------------------------------------------------------------------
-- Clicks -> intents (desktop: one click, one order)
-- ---------------------------------------------------------------------------------------------
session.intents = {}
click(neutral_adj)
expect(
	#session.intents == 1 and session.intents[1].type == "attack" and session.intents[1].tile == neutral_adj,
	"click neutral -> attack intent (expand)"
)
expect(last_float() == "Expanding with 2.50K", "expand float text: " .. last_float())
-- duplicate tap within DUP_MS is ignored
inter:on_click(neutral_adj)
expect(#session.intents == 1, "duplicate click ignored")
click(enemy_adj)
expect(
	#session.intents == 2 and session.intents[2].type == "attack" and session.intents[2].ratio == ctx.ratio,
	"click enemy -> attack"
)
click(swe_coast)
expect(#session.intents == 3 and session.intents[3].type == "boat", "click far coast -> boat")
-- the Attack bar: five stops, every match starts at the default one, and its position is not a
-- saved setting
do
	local before = ctx.ratio
	local fired = 0
	local conn = ctx.ratio_changed:Connect(function()
		fired += 1
	end)
	expect(
		table.concat(UICtx.RATIO_STOPS, " ") == "0.1 0.25 0.35 0.5 0.75" and UICtx.DEFAULT_RATIO == 0.25,
		"the stops: 10% 25% 35% 50% 75%, starting at 25%"
	)
	ctx:set_ratio(0.8)
	expect(ctx.ratio == 0.75 and ctx.settings.ratio == nil, "the bar moves to the nearest stop, and nothing is saved of it")
	ctx:set_ratio(1.0)
	expect(ctx.ratio == 0.75 and fired == 1, "nothing past 75%: the same stop, and nobody is told twice")
	ctx:set_ratio(0.01)
	expect(ctx.ratio == 0.1, "nothing under 10%")
	ctx:set_ratio(0.3)
	expect(ctx.ratio == 0.25, "half way between two stops is the lower one")
	ctx:set_ratio(0.31)
	expect(ctx.ratio == 0.35, "past half way, the upper one")
	-- Q / E and the wheel: one stop at a time, and they stop at the ends
	ctx:set_ratio(0.1)
	local walked = {}
	for _ = 1, 6 do
		ctx:step_ratio(1)
		table.insert(walked, ctx.ratio)
	end
	expect(table.concat(walked, " ") == "0.25 0.35 0.5 0.75 0.75 0.75", "step_ratio(+1) walks up the stops and stays on the last")
	ctx:step_ratio(-3) -- (a wheel's delta: its sign is what counts)
	expect(ctx.ratio == 0.5, "step_ratio(-n) is one stop down")
	for _ = 1, 6 do
		ctx:step_ratio(-1)
	end
	expect(ctx.ratio == 0.1, "and stays on the first")
	-- a cap (the tutorial's): the stops above it can't be had
	ctx:set_ratio(0.75)
	fired = 0
	ctx:set_ratio_max(0.5)
	expect(ctx.ratio == 0.5 and fired == 1, "a cap of 50% brings 75% down to 50%, and the bar is told")
	ctx:set_ratio(0.75)
	expect(ctx.ratio == 0.5, "under it the 75% stop gives 50%")
	ctx:step_ratio(1)
	expect(ctx.ratio == 0.5, "and a step up stays there")
	ctx:set_ratio_max(0.05)
	expect(ctx.ratio == 0.1, "a cap under every stop leaves the lowest")
	fired = 0
	ctx:set_ratio_max(1.0)
	expect(ctx.ratio == 0.1 and fired == 1, "lifting the cap leaves the ratio, and the bar is told (the faint stops light up)")
	fired = 0
	ctx:set_ratio(0.75)
	ctx:reset_ratio()
	expect(
		ctx.ratio == UICtx.DEFAULT_RATIO and fired == 2,
		"reset_ratio: back at the default stop, and the bar is told"
	)
	ctx.settings.ratio = 0.9
	ctx:reload_settings()
	expect(ctx.ratio == UICtx.DEFAULT_RATIO, "an old record's saved ratio is not read back")
	ctx.settings.ratio = nil
	ctx:set_ratio(before)
	conn:Disconnect()
end
click(ocean)
expect(#session.intents == 3, "click ocean -> no order")

-- Touch: look before you act (first tap selects, second fires)
ctx.touch = true
ctx.touch_device = true
session.intents = {}
click(enemy_adj)
expect(
	target_card.is_open and target_card.kind == "attack" and #session.intents == 0,
	"touch: first tap selects the target"
)
click(enemy_adj)
expect(
	not target_card.is_open and #session.intents == 1 and session.intents[1].type == "attack",
	"touch: second tap fires"
)
-- a tap elsewhere only closes the selection
click(enemy_adj)
click(neutral_adj)
expect(not target_card.is_open and #session.intents == 1, "touch: tap elsewhere closes without an order")
ctx.touch = false
ctx.touch_device = false

-- ---------------------------------------------------------------------------------------------
-- Build placement (desktop)
-- ---------------------------------------------------------------------------------------------
session.intents = {}
inter:select_action("city")
expect(inter.aim_kind == "city" and bar.placing == "city", "select_action(city) enters placement")
click(my_tile)
local it = session.intents[1]
expect(it ~= nil and it.type == "build" and it.kind == "city", "click own land builds a city")
expect(inter.aim_kind == "", "placement ends after one build (no Shift)")
expect(string.find(last_float(), "City", 1, true) ~= nil, "build float: " .. last_float())
-- not enough gold for a SAM (1.5M > gold 2M? gold 2M, SAM 1.5M: ok) -> silo: 1M ok; try hydrogen: needs a silo
inter:select_action("hydrogen")
expect(
	inter.aim_kind == "" and bar.denied[#bar.denied] == "hydrogen" and last_float() == "Requires a Missile Silo",
	"nuke without silo is denied: " .. last_float()
)

-- Nukes: add a finished silo, then two clicks to launch
gs:apply_delta({ t = gs.tick + 1, ev = { { Ev.STRUCT_ADD, 77, Defs.S_SILO, ME, gdansk + 2 } } })
if gs.structures[77] then
	gs.structures[77].active_tick = 0
end
ctx.rules:recount()
session.intents = {}
inter:select_action("atom")
expect(inter.aim_kind == "atom", "atom aim with a silo")
click(enemy_adj)
expect(
	#session.intents == 0 and string.find(last_float(), "Target locked", 1, true) ~= nil,
	"first click locks the target: " .. last_float()
)
click(enemy_adj)
expect(
	#session.intents == 1 and session.intents[1].type == "nuke" and session.intents[1].kind == "atom",
	"second click launches"
)

-- ---------------------------------------------------------------------------------------------
-- Radial items
-- ---------------------------------------------------------------------------------------------
local function ids_of(items: any): string
	local out = {}
	for _, i in items do
		table.insert(out, i.id .. (if i.ok then "" else "!"))
	end
	return table.concat(out, ",")
end
local r1 = ctx.rules:radial_items(enemy_adj)
print("    enemy radial:", ids_of(r1))
expect(r1[1].id == "attack" and r1[1].ok, "radial: attack first")
local has_ally, has_nuke = false, false
for _, i in r1 do
	has_ally = has_ally or i.id == "ally_request"
	has_nuke = has_nuke or (i.id == "nuke" and i.sub ~= nil and #i.sub == 3)
end
expect(has_ally and has_nuke, "radial: ally + nuke sub-ring on an enemy")
local r2 = ctx.rules:radial_items(my_tile)
print("    own radial:", ids_of(r2))
expect(r2[1].id == "build" and #r2[1].sub == 7 and r2[#r2].id == "info", "radial: build ring (7) on own land")
inter:on_context(enemy_adj, Vector2.new(300, 300))
expect(radial.is_open and radial.opened.title == "Poland", "on_context opens the radial with the owner's name")
radial:close()

-- ---------------------------------------------------------------------------------------------
-- BorderTracker incremental update
-- ---------------------------------------------------------------------------------------------
local changed = { neutral_adj * 1024 + ME }
buffer.writei32(gs.owner, neutral_adj * 4, ME)
bt:on_tiles_changed(changed)
bt._computed_msec = -100000
expect(bt.border[neutral_adj] == true, "newly conquered frontier tile is a border tile")

-- hover spec
ctx.touch = false
local spec = inter:hover_spec(enemy_adj)
expect(
	spec.title == "Poland" and spec.badge == "Neutral" and spec.hint ~= nil,
	"hover spec for an enemy: " .. tostring(spec.badge)
)
expect(spec.footer == "Right-click for more actions", "hover footer")

print(if fails == 0 then "ALL PASS" else ("FAILURES: " .. fails))
if fails > 0 then
	error("uiscreens_logic failed")
end
