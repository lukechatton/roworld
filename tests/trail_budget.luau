--!nocheck
-- Map/TrailBudget: how many trail dots and target rings the munitions in flight are drawn with (each
-- is a GUI object; a MIRV is 350 warheads).
-- Run: .bin/lune run tests/trail_budget.luau
local TrailBudget = require("../src/client/Map/TrailBudget")
local Rules = require("../src/shared/Core/Rules")

local fails, total = 0, 0
local function expect(cond: any, what: string)
	total += 1
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local MAX, BUDGET, RING_MAX = TrailBudget.MAX, TrailBudget.BUDGET, TrailBudget.RING_MAX

-- a few munitions: drawn as they always were
for _, n in { 0, 1, 2, 5 } do
	local dots, rings = TrailBudget.allowance(n)
	expect(dots == MAX and rings, ("%d in flight: whole trails, every target ring"):format(n))
end
do
	local dots, rings = TrailBudget.allowance(6) -- a scattershot's bus and its warheads
	expect(dots >= 100 and rings, "a scattershot's handful keep their trails and their rings")
end

-- never more than the budget, however many fly
local worst = 0
for n = 1, 3000 do
	local dots = TrailBudget.allowance(n)
	worst = math.max(worst, dots * n)
	if dots > MAX or dots < 0 or dots ~= math.floor(dots) then
		worst = math.huge
	end
end
expect(worst <= BUDGET, ("1 to 3,000 in flight: never more than %d dots in all (most: %d)"):format(BUDGET, worst))
do
	local prev = math.huge
	local falling = true
	for n = 1, 3000 do
		local dots = TrailBudget.allowance(n)
		falling = falling and dots <= prev
		prev = dots
	end
	expect(falling, "more munitions never means longer trails")
end

-- a MIRV, and three at once
do
	local n = Rules.MIRV_WARHEADS
	local dots, rings = TrailBudget.allowance(n)
	expect(n == 350, "a MIRV is 350 warheads")
	expect(dots >= 1 and dots * n <= BUDGET and not rings, ("one MIRV: %d dots a warhead, no rings"):format(dots))
	-- before the budget: a whole trail and a ring each
	expect(n * (MAX + 2) > 50000 and n * (dots + 1) < 1200, "its objects: tens of thousands before, about a thousand now")
	local dots3, rings3 = TrailBudget.allowance(n * 3)
	expect(dots3 == 0 and not rings3, "three MIRVs at once: the warheads alone")
end

-- the rings' threshold
do
	local _, at = TrailBudget.allowance(RING_MAX)
	local _, over = TrailBudget.allowance(RING_MAX + 1)
	expect(at and not over, ("warheads keep their rings up to %d munitions in flight"):format(RING_MAX))
end

print(("trail_budget: %d/%d passed"):format(total - fails, total))
if fails > 0 then
	error(("trail_budget: %d failures"):format(fails))
end
