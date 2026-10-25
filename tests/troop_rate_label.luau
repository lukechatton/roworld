--!nocheck
-- Troop regrowth and the command bar's troops/s label.
--   troopIncreaseRate: toAdd = (10 + troops^0.73 / 4) * (1 - troops / maxTroops), bots x0.5,
--     nations x{0.9, 0.95, 1.0} by difficulty; returns min(troops + toAdd, max) - troops.
--   The label: green while troopIncreaseRate >= the previous sample, orange
--     once it drops; it reads "+NumberFormat.render_troops(rate * 10)/s", clamped at 0.
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Rules = require("../src/shared/Core/Rules")
local UIRules = require("../src/client/UI/UIRules")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local NATION_GROWTH = { 0.9, 0.95, 1.0 } -- Easy / Medium / Hard

-- The growth formula, written out here (not taken from Rules) so the two are checked against
-- each other.
local function formula_rate(kind: number, troops: number, max: number, difficulty: number): number
	local toAdd = 10 + troops ^ 0.73 / 4
	toAdd *= 1 - troops / max
	if kind == Defs.KIND_TRIBE then
		toAdd *= 0.5
	elseif kind == Defs.KIND_NATION then
		toAdd *= NATION_GROWTH[difficulty + 1]
	end
	return math.min(troops + toAdd, max) - troops
end

for _, kind in ipairs({ Defs.KIND_HUMAN, Defs.KIND_NATION, Defs.KIND_TRIBE }) do
	for _, d in ipairs({ 0, 1, 2 }) do
		local worst = 0.0
		for _, max in ipairs({ 30000.0, 100000.0, 612345.0, 4.2e6 }) do
			for k = 0, 40 do
				local troops = max * k / 32 -- includes troops above the cap
				local a = Rules.troop_growth(kind, troops, max, d)
				local b = formula_rate(kind, troops, max, d)
				worst = math.max(worst, math.abs(a - b) / math.max(1.0, math.abs(b)))
			end
		end
		-- (nation multipliers are the same doubles as the literals above)
		expect(worst < 1e-6, string.format("troop_growth == troopIncreaseRate (kind %d, difficulty %d)", kind, d))
	end
end

-- Fall-off shape: the rate peaks at an interior troop count, rises before it and falls after it.
local max = Rules.max_troops(Defs.KIND_HUMAN, 400, 0, 1)
local best_t, best_r = 0.0, -math.huge
for t = 0, max, max / 2000 do
	local r = Rules.troop_growth(Defs.KIND_HUMAN, t, max, 1)
	if r > best_r then
		best_t, best_r = t, r
	end
end
expect(
	best_t > 0.05 * max and best_t < 0.95 * max,
	string.format("rate peaks inside (0, max): %.0f of %.0f", best_t, max)
)

-- The label, sampled like CommandBar.sample_growth (once per stats update; reset on bind).
local owner = { kind = Defs.KIND_HUMAN, troops = 0.0, max_troops = max }
local rate_up, last = true, nil
local function reset()
	rate_up, last = true, nil
end
local function sample(troops: number, cap: number?)
	owner.troops = troops
	owner.max_troops = cap or max
	local rate = Rules.troop_growth(owner.kind, owner.troops, math.max(owner.max_troops, 1), 1)
	rate_up = UIRules.troop_rate_rising(rate, last)
	last = rate
	return rate_up
end

expect(sample(best_t * 0.2) == true, "first sample is green (no previous rate)")
expect(sample(best_t * 0.6) == true, "below the optimum, growing troops -> rate rising -> green")
expect(sample(best_t * 0.6) == true, "same rate as the previous sample -> green (>=)")
expect(sample(best_t * 1.5) == false, "past the optimum -> rate falling -> orange")
expect(sample(best_t * 1.8) == false, "still falling -> orange")
expect(sample(best_t * 0.9) == true, "troops spent on an attack (back under the optimum) -> rate up -> green")
-- Losing land lowers the cap: same troops, smaller max -> lower rate -> orange.
local small = Rules.max_troops(Defs.KIND_HUMAN, 200, 0, 1)
expect(sample(best_t * 0.9, small) == false, "cap drops after losing land -> orange")
-- Above the (new) cap the rate is negative (troops snap down), then holds at 0 -> green again.
expect(sample(small * 1.3, small) == false, "above the cap -> negative rate -> orange")
expect(sample(small, small) == true, "at the cap, rate 0 >= negative -> green")
expect(sample(small, small) == true, "holding at the cap -> green")
reset()
expect(sample(small * 1.3, small) == true, "after a reset the first sample is green again")

-- Text: "+X/s", clamped at 0 like NumberFormat.render_number.
local T = require("../src/client/UI/UITheme")
expect(UIRules.troop_rate_text(12345) == "+1.23K/s", "label text +X/s in display units (internal / 10, floored)")
expect(UIRules.troop_rate_text(-5000) == "+0/s", "negative rate reads +0/s")

print(if fails == 0 then "troop_rate_label: all passed" else string.format("troop_rate_label: %d FAILED", fails))
if fails > 0 then
	error("troop_rate_label failed")
end
