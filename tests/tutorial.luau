--!nocheck
-- The new player's tutorial: who counts as new, the steps and their funnel, the Stars paid once, and
-- Staging's reset. Run: .bin/lune run tests/tutorial.luau
require("./prelude")
local Tutorial = require("../src/shared/Data/Tutorial")
local Purchases = require("../src/server/Purchases")
local Analytics = require("../src/server/Analytics")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- who is new
expect(Tutorial.is_new({}, {}), "nothing saved: new")
expect(Tutorial.is_new(nil, nil), "no settings at all: new")
expect(Tutorial.is_new({ tutorial = "" }, { matches = 0 }), "Staging's reset: new again")
expect(not Tutorial.is_new({ tutorial = "started" }, {}), "the tutorial was started once: not new")
expect(not Tutorial.is_new({ tutorial = "done" }, {}), "done: not new")
expect(not Tutorial.is_new({}, { matches = 3 }), "matches played before the tutorial existed: not new")
expect(not Tutorial.is_new({ tips_seen = { expand = true } }, {}), "tips seen before it existed: not new")
expect(Tutorial.is_new({ tips_seen = {} }, { matches = "x" }), "junk counts as nothing")

-- the steps and the funnel
expect(#Tutorial.FUNNEL == #Tutorial.STEPS + 2, "the funnel is Started, a step each, Completed")
local seen = {}
for i, s in Tutorial.STEPS do
	expect(type(s.touch) == "string" and #s.touch <= 40, s.id .. ": a phone line of at most 40 characters")
	expect(Tutorial.funnel_step(s.id) == i + 1 and not seen[s.id], s.id .. ": its own funnel step")
	seen[s.id] = true
end
expect(Tutorial.funnel_step("nope") == nil, "an unknown step has none")
expect(Tutorial.grow_goal(100) == 400, "a small nation is asked for GROW_MIN more land")
expect(Tutorial.grow_goal(1000) == 3000, "a bigger one for GROW_FACTOR times its land")

-- the slider's cap and the floor under the army
expect(Tutorial.RATIO_CAP <= 0.5 and Tutorial.RATIO_HIGH <= Tutorial.RATIO_CAP, "the slider stops at half the army or less")
expect(Tutorial.TROOP_FLOOR > 0 and Tutorial.FLOOR_ARM > Tutorial.TROOP_FLOOR, "the floor arms above itself")
expect(Tutorial.COUNTDOWN_TICKS <= 15, "the tutorial's match starts within 1.5 s of the capital")
do
	local UICtx = require("../src/client/UI/UICtx")
	local me = { troops = 10000, max_troops = 20000 }
	local c = { ratio = 0.4, troop_floor = nil, floor_share = UICtx.floor_share, my = function()
		return me
	end }
	expect(UICtx.order_ratio(c) == 0.4, "no floor: the slider's share goes")
	c.troop_floor = 0.25
	expect(UICtx.order_ratio(c) == 0.4, "an army well above the floor sends the slider's share")
	me.troops = 6000
	expect(math.abs(UICtx.order_ratio(c) - 1000 / 6000) < 1e-9, "near the floor the order is trimmed to what may go")
	me.troops = 5050
	expect(UICtx.order_ratio(c) == 0, "at the floor nothing goes")
	me.troops = 3000
	expect(UICtx.order_ratio(c) == 0, "nor below it")
	me.max_troops = 0
	expect(UICtx.order_ratio(c) == 0.4, "without a cap known the slider's share goes")
	-- every order passes UICtx.send: there the floor holds whoever built the order
	me.troops, me.max_troops = 6000, 20000
	local sent = {}
	local held = 0
	local sender = {
		ratio = 0.4,
		troop_floor = 0.25,
		floor_share = UICtx.floor_share,
		floor_held = { Fire = function()
			held += 1
		end },
		my = c.my,
		sent_log = {},
		session = { send_intent = function(_, it)
			table.insert(sent, it)
		end },
	}
	UICtx.send(sender, { type = "attack", tile = 1, ratio = 1.0 })
	expect(#sent == 1 and math.abs(sent[1].ratio - 1000 / 6000) < 1e-9, "an order for everything is held to what may go")
	expect(held == 1, "and the floor says it held one back")
	me.troops = 4000
	UICtx.send(sender, { type = "attack", tile = 1, ratio = 0.5 })
	expect(#sent == 1 and #sender.sent_log == 1, "below the floor it is not sent")
	expect(held == 2, "nor that one")
	UICtx.send(sender, { type = "build", kind = "city", tile = 1 })
	expect(#sent == 2 and held == 2, "other orders are not its business")
	me.troops = 20000
	UICtx.send(sender, { type = "attack", tile = 1, ratio = 0.4 })
	expect(#sent == 3 and held == 2, "an order the floor leaves alone says nothing")
end

-- the tutorial's floor waits until after "grow" (2026-10-27)
expect((Tutorial.step_index(Tutorial.FLOOR_FROM) or 0) > (Tutorial.step_index("grow") or math.huge), "no floor before the first neighbour")
do
	-- grow teaches expand, let the troops refill, expand again: never "keep tapping"
	local g = Tutorial.STEPS[Tutorial.step_index("grow")]
	for _, line in { g.touch, g.desktop, g.wait } do
		expect(not string.find(string.lower(line), "keep"), "grow never says keep tapping: " .. line)
	end
	expect(type(g.wait) == "string" and #g.wait <= 40, "grow's wait line fits a phone's card")
	expect(Tutorial.GROW_READY > 0.15 and Tutorial.GROW_READY < 0.5, "an expansion counts with the army part refilled")
end

-- a new player's floor after the tutorial: their first ROOKIE_MATCHES matches (2026-10-27)
expect(Tutorial.rookie(0) and Tutorial.rookie(Tutorial.ROOKIE_MATCHES - 1), "the first matches are a new player's")
expect(not Tutorial.rookie(Tutorial.ROOKIE_MATCHES), "the next is not")
expect(Tutorial.ROOKIE_FLOOR > 0 and Tutorial.FLOOR_ARM > Tutorial.ROOKIE_FLOOR, "the new player's floor arms above itself")
do
	local Telemetry = require("../src/client/UI/Telemetry")
	local saved = { matches = 3 }
	local tel = Telemetry.new({ session = { load_settings = function(_, section)
		return if section == "stats" then saved else {}
	end } })
	expect(tel:matches_before() == 3, "matches before: the server's count")
	tel.matches_started = 1
	tel._match = { ended = false }
	expect(tel:matches_before() == 3, "the match being played is not one before it")
	tel._match.ended = true
	expect(tel:matches_before() == 4, "once it is over, it is")
	tel:new_player()
	expect(tel:matches_before() == 0, "replaying as a new player: none")
end
do
	local UIAdvisor = require("../src/client/UI/UIAdvisor")
	local me = { troops = 10000, max_troops = 40000 }
	local before = 2
	local ctx = { troop_floor = nil }
	function ctx.alive_player()
		return true
	end
	function ctx.my()
		return me
	end
	local ui = { ctx = ctx, tutorial = { active = false }, telemetry = { matches_before = function()
		return before
	end } }
	local adv = UIAdvisor.new(ui)
	adv:check_floor()
	expect(ctx.troop_floor == nil, "a new player's floor waits for the army to grow")
	me.troops = 15000
	adv:check_floor()
	expect(ctx.troop_floor == Tutorial.ROOKIE_FLOOR, "then an order leaves a fifth of the cap at home")
	ctx.troop_floor = nil
	before = Tutorial.ROOKIE_MATCHES
	adv:check_floor()
	expect(ctx.troop_floor == nil, "not after the first matches")
	before = 0
	ui.tutorial.active = true
	adv:check_floor()
	expect(ctx.troop_floor == nil, "the tutorial keeps its own")
end

-- the Stars, once
local store = {}
local sent = {}
Purchases.configure({
	datastore = {
		UpdateAsync = function(_, k, fn)
			local v = fn(store[k])
			if v ~= nil then
				store[k] = v
			end
		end,
		GetAsync = function(_, k)
			return store[k]
		end,
	},
	inventory = function(player, inv)
		table.insert(sent, inv)
	end,
	log = function() end,
})
local p = { UserId = 7, Name = "P" }
expect(Purchases.tutorial_bonus(p, Tutorial.STARS) == true, "the tutorial's Stars are paid")
expect(Purchases.stars(p) == Tutorial.STARS, "to the balance")
expect(Purchases.tutorial_bonus(p, Tutorial.STARS) == false, "and not a second time")
expect(Purchases.stars(p) == Tutorial.STARS, "the balance stays")
expect(Purchases.tutorial_bonus(p, 0) == false and Purchases.tutorial_bonus(p, 0 / 0) == false, "nothing for no amount")
-- Staging: a new player again
store["u7"].crates_bought = 4
expect(Purchases.reset_new_player(p) == true, "Staging's reset goes through")
expect(store["u7"].crates_bought == 0 and store["u7"].tutorial_paid == nil, "no crate bought, no bonus paid")
expect(store["u7"].stars == Tutorial.STARS, "what is owned stays")
expect(Purchases.tutorial_bonus(p, Tutorial.STARS) == true and Purchases.stars(p) == 2 * Tutorial.STARS, "the bonus can be earned again")

-- the funnel on the server: each step once a match, in a match only
local logged = {}
local events = {}
Analytics.configure({
	onboarding = function() end,
	funnel = function(player, funnel, key, step, name)
		table.insert(logged, funnel .. ":" .. step .. ":" .. name)
	end,
	custom = function(player, name, value, f)
		table.insert(events, name .. ":" .. tostring(f[#f]))
	end,
	guid = function()
		return "k"
	end,
	tutorial_steps = Tutorial.FUNNEL,
})
local a = { UserId = 9, Name = "A" }
Analytics.joined(a)
Analytics.report(a, "tutorial", 1)
expect(#logged == 0, "a step outside a match is not logged")
Analytics.report(a, "match_start", "solo0", "world")
local before = #logged
Analytics.report(a, "tutorial", 1)
Analytics.report(a, "tutorial", 1)
Analytics.report(a, "tutorial", 3)
Analytics.report(a, "tutorial", 99)
Analytics.report(a, "tutorial", "x")
expect(#logged == before + 2, "each real step once")
expect(logged[#logged] == "Tutorial:3:First Tap" and logged[#logged - 1] == "Tutorial:1:Started", "under its name")
Analytics.report(a, "tutorial_skip", 3)
expect(events[#events] == "Tutorial Skipped:Grew", "a skip names the step it was on")
expect(Tutorial.funnel_step("attack") < Tutorial.funnel_step("ratio"), "the neighbour comes before the slider")
expect(Tutorial.RATIO_HIGH <= 0.5 and Tutorial.RATIO_LOW > 0.2, "the slider step asks for a moderate share, never everything")
do
	-- the step asks for one stop of the Attack bar: the next one up from where the bar starts, so a
	-- single tap passes it, and no other stop does
	local UICtx = require("../src/client/UI/UICtx")
	local passing, goal_i, start_i = 0, 0, 0
	for i, stop in UICtx.RATIO_STOPS do
		if stop >= Tutorial.RATIO_LOW and stop <= Tutorial.RATIO_HIGH then
			passing += 1
		end
		if stop == Tutorial.RATIO_GOAL then
			goal_i = i
		end
		if stop == UICtx.DEFAULT_RATIO then
			start_i = i
		end
	end
	expect(passing == 1 and goal_i > 0, "exactly one stop passes the step, and it is the one asked for")
	expect(Tutorial.RATIO_GOAL >= Tutorial.RATIO_LOW and Tutorial.RATIO_GOAL <= Tutorial.RATIO_HIGH, "RATIO_GOAL is inside what passes")
	expect(goal_i == start_i + 1, "it is the next stop up from where the bar starts")
	expect(Tutorial.RATIO_GOAL <= Tutorial.RATIO_CAP, "and under the tutorial's cap")
	expect(Tutorial.RATIO_HOLD_S <= 0.25 and Tutorial.RATIO_MAX_S < Tutorial.STEP_MAX_S, "it passes at once, and nobody waits on it as long as on the others")
	local pct = string.format("%d%%", Tutorial.RATIO_GOAL * 100 + 0.5)
	for _, s in Tutorial.STEPS do
		if s.id == "ratio" then
			expect(string.find(s.touch, pct, 1, true) ~= nil and string.find(s.desktop, pct, 1, true) ~= nil, "the card names the stop")
			expect(#s.touch <= 40, "the phone line fits the card")
			expect(s.max_s == Tutorial.RATIO_MAX_S, "the step has its own wait")
		end
	end
	expect(string.find(Tutorial.RATIO_TOO_MUCH, pct, 1, true) ~= nil, "so does the line for too much")
end
for _, s in Tutorial.STEPS do
	expect(not string.find(string.lower(s.touch .. s.desktop), "100%", 1, true), s.id .. ": no step speaks of 100%")
end

if fails > 0 then
	error(fails .. " failures")
end
print("tutorial: all passed")
