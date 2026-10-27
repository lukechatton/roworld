--!nocheck
-- RoWorld General (Data/Subscription, server/General, Purchases.general_perks, the Rewards bonus;
-- 2026-10-27): who is subscribed, a crate (or Stars) once a UTC day, the month's skin kept for good,
-- +50% Stars on every match. Run: .bin/lune run tests/general.luau
require("./prelude")
local Subscription = require("../src/shared/Data/Subscription")
local Cosmetics = require("../src/shared/Data/Cosmetics")
local Stars = require("../src/shared/Data/Stars")
local Purchases = require("../src/server/Purchases")
local Rewards = require("../src/server/Rewards")
local General = require("../src/server/General")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- the data
local DAY = 86400
local oct27 = 1792972800 + 12 * 3600 -- 2026-10-27 12:00 UTC
expect(Subscription.day(oct27) == Subscription.day(oct27 + 11 * 3600), "one UTC day")
expect(Subscription.day(oct27 + 12 * 3600) == Subscription.day(oct27) + 1, "midnight UTC starts the next")
local skin = Subscription.skin_for(oct27)
expect(skin ~= nil and Cosmetics.item(skin) ~= nil and Cosmetics.item(skin).general, "October has a General skin")
expect(Subscription.skin_for(oct27 + 60 * DAY) == skin, "a month without its own keeps the latest")
expect(Subscription.skin_for(0) == Subscription.SKINS[1].skin, "before the first: the first")
expect(Subscription.bonus(1000, 5) == 500 and Subscription.bonus(33, 5) == 15, "the bonus: half, in whole Stars quanta")
for _, it in Cosmetics.generals() do
	expect(not table.find(Cosmetics.all(), it), "  " .. it.name .. " is not in a crate")
	expect(Cosmetics.may_own(it.id, 1) and Cosmetics.rarity(it.rarity) == Cosmetics.GENERAL, "  anyone given it may own it")
	expect(Cosmetics.crate_owned({ [it.id] = true }) == 0, "  not in the Locker's N of M")
end

-- Purchases.general_perks: a store as purchases.luau's
local rows = {}
local down = false
local store = {}
function store:UpdateAsync(k, fn)
	if down then
		error("DataStore request was throttled")
	end
	local new = fn(rows[k])
	if new ~= nil then
		rows[k] = new
	end
	return new
end
function store:GetAsync(k)
	if down then
		error("DataStore unavailable")
	end
	return rows[k]
end
local P = { UserId = 7, Name = "Gen" }
local invs = {}
Purchases.configure({
	datastore = store,
	notify = function() end,
	inventory = function(_, inv)
		table.insert(invs, inv)
	end,
})
Purchases.load(P)
local day = Subscription.day(oct27)
local g = Purchases.general_perks(P, day, skin, true)
expect(g ~= nil and g.crate == true and g.skin == skin and g.stars == nil, "a General's day: a crate and the month's skin")
expect(Purchases.credits(P).crate == 1, "the crate is a credit (the Locker opens it)")
local inv = Purchases.inventory(P)
expect(table.find(inv.owned, skin) ~= nil and inv.equipped.skin == skin, "the skin is theirs, and on (none was worn)")
g = Purchases.general_perks(P, day, skin, true)
expect(g ~= nil and next(g) == nil and Purchases.credits(P).crate == 1, "the same day again: nothing")
Purchases.equip(P, "skin", false)
g = Purchases.general_perks(P, day + 1, skin, false)
expect(g ~= nil and g.stars == Subscription.DAILY_STARS and g.crate == nil and g.skin == nil, "no crates here: Stars instead")
expect(Purchases.stars(P) == Subscription.DAILY_STARS, "  paid")
expect(Purchases.equipped(P) == nil, "a skin given before is not put on again")
down = true
expect(Purchases.general_perks(P, day + 2, skin, true) == nil, "the store down: nil (tried again later)")
down = false

-- server/General
local subscribed = {}
local status_calls = 0
local answered = true
local sent = {}
local perks = {}
local t = oct27
General.configure({
	status = function(p)
		status_calls += 1
		if not answered then
			error("HTTP 500")
		end
		return subscribed[p] == true
	end,
	perks = function(p, d, s)
		table.insert(perks, { p, d, s })
		return { crate = true }
	end,
	send = function(p, st)
		table.insert(sent, { p, st })
	end,
	now = function()
		return t
	end,
})
Subscription.ID = "EXP-1"
local A, B = { UserId = 1 }, { UserId = 2 }
subscribed[A] = true
General.joined(A)
General.joined(B)
expect(General.active(A) and not General.active(B), "joined: Roblox says who is subscribed")
expect(#perks == 1 and perks[1][1] == A and perks[1][2] == Subscription.day(t) and perks[1][3] == skin, "a General's day on joining")
expect(#sent == 3 and sent[1][2].on == true and sent[3][2].on == false, "each client told")
General.tick()
expect(#perks == 1, "the tick the same day: nothing")
t += DAY
General.tick()
expect(#perks == 2 and perks[2][2] == Subscription.day(t), "a new UTC day: its perks")
subscribed[B] = true
General.changed(B)
expect(General.active(B) and #perks == 3 and perks[3][1] == B, "subscribing: a General at once, with the day's perks")
subscribed[A] = false
General.changed(A)
expect(not General.active(A), "cancelled: no longer")
t += DAY
General.tick()
expect(#perks == 4 and perks[4][1] == B, "only Generals get a day")
answered = false
General.changed(B)
expect(General.active(B), "Roblox not answering changes nothing")
answered = true
General.release(B)
expect(not General.active(B), "released")
Subscription.ID = ""
local before = #sent
General.joined({ UserId = 3 })
expect(#sent == before, "no subscription in this experience: nothing")

-- Rewards: +50% on top of 2x Stars
local paid = {}
local doubled, general = false, false
Rewards.configure({
	add_stars = function(_, n)
		return true, n
	end,
	double = function()
		return doubled
	end,
	general = function()
		return general
	end,
	send = function(_, payload)
		table.insert(paid, payload)
	end,
})
local result = { spawned = true, left = false, won = false, minutes = 10, shares = 2, kills = 1, place = 3, field = 40 }
local base = Rewards.pay(P, result, "public")
general = true
local with = Rewards.pay(P, result, "public")
expect(with == base + Subscription.bonus(base, Stars.QUANTUM), "a General's match: +50%")
expect(paid[#paid].lines[#paid[#paid].lines][1] == "general", "  its own line")
doubled = true
local both = Rewards.pay(P, result, "public")
expect(both == base * 2 + Subscription.bonus(base, Stars.QUANTUM), "with 2x Stars: doubled, then +50% of the match's")
expect(Stars.LABELS.general ~= nil, "the line has a label")

if fails > 0 then
	print(string.format("general: %d FAILED", fails))
	error("general tests failed")
end
print("general: all passed")
