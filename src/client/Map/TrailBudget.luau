--!strict
-- How much of the munitions in flight UnitLayer draws: every trail dot and every target ring is a
-- GUI object, so their number has a ceiling whatever the Sim has in the air.
--
-- A munition's trail is a dot every UnitLayer.TRAIL_STEP along the arc it has flown, MAX at most. All
-- the munitions in flight share BUDGET dots a redraw: with more of them than the budget feeds whole
-- trails, each keeps only its newest dots (the tail behind it), down to none.
--   * A MIRV is 350 warheads (Rules.MIRV_WARHEADS), and the AI fires them at a leader who nears the
--     win. Each warhead had its whole trail and a pulsing target ring. One MIRV on a World map,
--     measured 2026-10-09 on the Mac that measures docs/performance.md: 208 warheads, 16,784 objects
--     in the unit layer where 1,000 had been, 27 ms of its script a frame where 2 had been, frames of
--     183 ms. A player's report the same day: "I went down to like 3fps nearing the end of a rofront
--     game".
--   * so the trails share a budget, and MIRV warheads lose their target rings while many fly.
--
-- Pure Luau (no Roblox types): tests/trail_budget.luau.
local TrailBudget = {}

--- The most dots one trail has.
TrailBudget.MAX = 160
--- Dots a redraw draws for all the trails together.
TrailBudget.BUDGET = 800
--- A MIRV warhead's target ring is drawn while no more than this many munitions are in flight (a
--- scattershot's handful keep theirs; 350 rings said nothing a player could read). Every other
--- munition always has its ring.
TrailBudget.RING_MAX = 24

--- With `flying` trailed munitions in the air: the dots each one keeps (MAX: its whole trail; 0:
--- none), and whether MIRV warheads get their target rings.
function TrailBudget.allowance(flying: number): (number, boolean)
	return math.min(TrailBudget.MAX, TrailBudget.BUDGET // math.max(flying, 1)), flying <= TrailBudget.RING_MAX
end

return TrailBudget
