-- gameplay-fixer: headless checks for the review_gameplay.md UI fixes that are pure logic
-- (run: .bin/lune run tests/gameplayfixer_ui.luau).
--  * P1-5: donations are capped at the ally's troop headroom (UIRules.donate_plan), the radial item
--    and UIInteract.donate_to send the capped amount, and nothing is sent at the cap. The Sim rule
--    itself is untouched (checked: Sim.donate still accepts any amount).
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local GameState = require("../src/shared/Core/GameState")
local WorldMap = require("../src/shared/Core/WorldMap")
local Places = require("./world_places")
local UICtx = require("../src/client/UI/UICtx")
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
local ME, ALLY = 239, 5

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
local home = Places.latlon_to_tile(54.0, 18.4)
local ally_home = home + 12 * W
block(home, 5, ME)
block(ally_home, 6, ALLY)

local function snapshot(ally_troops: number, ally_cap: number)
	return {
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
			{ ME, "Luke", 0x719bfaff, Defs.KIND_HUMAN, 0, true, 100, 1000000, 2000000, 3000000, 1000, 0, home },
			{
				ALLY,
				"United Kingdom",
				0xff4040ff,
				Defs.KIND_NATION,
				0,
				true,
				100,
				ally_troops,
				10000,
				ally_cap,
				1000,
				0,
				ally_home,
			},
		},
		structs = {},
		roads = {},
		units = {},
		nukes = {},
		shells = {},
		sam_missiles = {},
		attacks = {},
		allies = { { ME, ALLY } },
		requests = {},
	}
end

local function setup(ally_troops: number, ally_cap: number)
	local gs = GameState.new(map)
	gs:load_snapshot(snapshot(ally_troops, ally_cap))
	gs.local_owner = ME
	local session = { mode = UICtx.MODE_SOLO, state = gs, lobby = {}, intents = {} }
	function session.send_intent(self: any, intent: any)
		table.insert(self.intents, intent)
	end
	local ctx = UICtx.new()
	ctx.session = session
	ctx.world = {}
	ctx.state = gs
	ctx.state_mode = UICtx.MODE_SOLO
	ctx.ratio = 0.35
	ctx.borders:bind(gs, ME)
	ctx.rules:recount()
	local inter = UIInteract.new(ctx)
	local floats = {}
	inter._float = function(_self: any, text: string, icon: string, _col: any, _pos: any)
		table.insert(floats, { text = text, icon = icon })
	end
	return ctx, session, inter, floats, gs
end

print("P1-5 donation headroom")
do
	-- Plenty of room: the ratio share goes through untouched.
	local ctx, session, inter, floats = setup(100000, 3000000)
	local plan = ctx.rules:donate_plan(ALLY)
	expect(
		plan.want == 350000 and plan.amount == 350000 and not plan.capped and not plan.full,
		"room: full ratio share (350K)"
	)
	expect(inter:donate_to(ALLY, Vector2.zero) == true, "room: donate_to sends")
	local it = session.intents[#session.intents]
	expect(it and it.type == "donate" and it.target == ALLY and it.troops == 350000, "room: intent carries 350K")
	expect(
		floats[#floats].text == "Sent 35.0K troops to United Kingdom",
		"room: float text '" .. floats[#floats].text .. "'"
	)
end
do
	-- The review's case: UK close to its cap. Only the headroom is sent, and the float says why.
	local ctx, session, inter, floats = setup(309000, 340668)
	local plan = ctx.rules:donate_plan(ALLY)
	expect(plan.room == 31668 and plan.amount == 31668 and plan.capped and not plan.full, "near cap: capped at 31,668")
	inter:donate_to(ALLY, Vector2.zero)
	local it = session.intents[#session.intents]
	expect(it and it.troops == 31668, "near cap: intent carries only the headroom")
	expect(
		string.find(floats[#floats].text, "is now at its troop cap", 1, true) ~= nil,
		"near cap: float explains the cap ('" .. floats[#floats].text .. "')"
	)
	-- radial item carries the capped amount
	local items = ctx.rules:radial_items(ally_home)
	local don = nil
	for _, i in items do
		if i.id == "donate" then
			don = i
		end
	end
	expect(don ~= nil and don.ok and don.troops == 31668 and don.capped, "near cap: radial Donate shows 31.7K, capped")
end
do
	-- At the cap (< 1 % room): Donate is disabled, nothing is sent, the player is told.
	local ctx, session, inter, floats = setup(340000, 340668)
	local plan = ctx.rules:donate_plan(ALLY)
	expect(plan.full, "at cap: plan.full")
	local n = #session.intents
	expect(inter:donate_to(ALLY, Vector2.zero) == false and #session.intents == n, "at cap: no intent sent")
	expect(
		floats[#floats].text == "United Kingdom is at its troop cap",
		"at cap: deny float '" .. floats[#floats].text .. "'"
	)
	local items = ctx.rules:radial_items(ally_home)
	for _, i in items do
		if i.id == "donate" then
			expect(not i.ok and i.reason == "At their troop cap", "at cap: radial Donate disabled with a reason")
		end
	end
end
do
	-- No troops of my own: unchanged message.
	local ctx, _session, inter, floats = setup(100000, 3000000)
	ctx.ratio = 0.0
	expect(inter:donate_to(ALLY, Vector2.zero) == false, "no troops: refused")
	expect(floats[#floats].text == "No troops to spare", "no troops: float")
end
do
	-- Sim rule untouched: Sim.donate still moves the full requested amount (the cap is UI-only).
	local src = require("@lune/fs").readFile("src/shared/Core/Sim.luau")
	expect(
		string.find(src, "local amount = math.clamp(troops, 0.0, math.max(self.o_troops[id], 0.0))", 1, true) ~= nil,
		"Sim.donate unchanged (no cap clamp in the rules)"
	)
end

if fails > 0 then
	print(string.format("gameplayfixer_ui: %d FAILED", fails))
	error("failures")
end
print("gameplayfixer_ui ok")
