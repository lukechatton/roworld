--!strict
-- A new player's first match (2026-10-04: an updated tutorial for new players, designed for phones
-- first, since 90% of the players are on a phone, with its steps drawn from the analytics funnels).
-- The onboarding funnel of the 28 days before it (202,158 new players):
--
--   Joined 100% -> Title 99% -> Match Started 85% -> Spawned 81% -> First Attack 66%
--   -> Survived 3 Min 32% -> Survived 10 Min 24% -> Second Match 21%
--
--   * 14% never start a match: the first match starts by itself, on this device, at once;
--   * 5% never pick a start: a spot is pointed out, and taken for them after AUTO_SPAWN_S;
--   * 19% spawn and never attack: the first step is the first tap, with the place to tap marked;
--   * half of those who attack are gone within 3 minutes, while the AI may not even attack them
--     yet (Rules.HUMAN_GRACE_TICKS): they leave with nothing to do. So the first minutes are a list
--     of small goals with a reward at the end, on a match with fewer tribes in the way (TRIBES)
--     and the gentlest AI (DIFFICULTY).
--
-- The match is an ordinary solo match otherwise: it goes on after the last step. client/UI/Tutorial
-- runs the steps; server/Analytics logs them as the "Tutorial" funnel (FUNNEL); the Stars are paid
-- once per player (server/Purchases.tutorial_bonus).
local Tutorial = {}

--- Stars for finishing it (5% of the cheapest Arsenal unlock: the bar on its card moves).
Tutorial.STARS = 1000
--- Tribes on the tutorial's map (a normal match has Rules.DEFAULT_TRIBES, 400): room to grow fast.
Tutorial.TRIBES = 60
Tutorial.DIFFICULTY = 0
--- Ticks (10 a second) from placing the capital to the match starting. A solo match waits 50, but
--- (2026-10-04) a 5 s wait after placing the capital confused new players, so the tutorial's round
--- starts much sooner.
Tutorial.COUNTDOWN_TICKS = 10
--- The Attack bar while the tutorial runs: it starts at the default and stops at RATIO_CAP (the
--- player's saved setting could leave it at about 85%, which is too much; 2026-10-04).
Tutorial.RATIO_CAP = 0.5
--- Keeps players from going too low in troop count (2026-10-04): while the tutorial
--- runs an order leaves at least TROOP_FLOOR of the army's cap at home (it is trimmed to what may go,
--- and refused when nothing may). The floor holds from the first time the army reaches FLOOR_ARM of
--- its cap: a new nation starts below it.
---   * Not before the FLOOR_FROM step (2026-10-27): on "grow" it refused taps the card asked for
---     ("Troops low. Let them grow back" under the card's "Keep tapping empty land to grow"), since
---     the cap climbs with every tile taken. Grow lost 11.6% of the players who reached it, the most
---     of any step, and 110,302 of its 175,898 left with Skip (the week to 2026-10-26). Before the
---     first neighbour there is nobody to fear, and the Attack bar's cap (RATIO_CAP) still holds.
Tutorial.TROOP_FLOOR = 0.25
Tutorial.FLOOR_ARM = 0.35
Tutorial.FLOOR_FROM = "attack"
Tutorial.FLOOR_REASON = "Troops low. Let them grow back"
--- A new player's first ROOKIE_MATCHES matches (the tutorial's among them) keep a floor under the
--- army after the tutorial too (2026-10-27): an order leaves ROOKIE_FLOOR of the army's cap at home,
--- from the first time the army reaches FLOOR_ARM of it (client/UI/UIAdvisor.check_floor). An army
--- spent below a fifth of its cap all but loses the match, and 23% of matches ended within their
--- first 3 minutes (Match funnel, the week to 2026-10-26). The first order held back in a match
--- says why (Coach "floor").
Tutorial.ROOKIE_MATCHES = 5
Tutorial.ROOKIE_FLOOR = 0.2

--- True while a player with `matches_before` matches before this one is still a new player.
function Tutorial.rookie(matches_before: number): boolean
	return matches_before < Tutorial.ROOKIE_MATCHES
end
--- Seconds on the spawn step before a start is picked for the player.
Tutorial.AUTO_SPAWN_S = 12
--- "grow": GROW_TAPS more expansions, and this many times the land the nation had when the step began
--- (at least GROW_MIN tiles more). On open land one order alone triples a new nation, so the
--- expansions count. It teaches the rhythm, never "keep tapping" (2026-10-27: the card said "Keep
--- tapping empty land to grow", which is bad advice: an order sent on an emptied army leaves the
--- nation open, and a small army regrows slowly). An expansion counts when it is sent with the army
--- at GROW_READY of its cap or more; below that the card says to let the troops refill and the mark
--- is on the troop count, and taps meanwhile don't count.
Tutorial.GROW_TAPS = 2
Tutorial.GROW_READY = 0.3
Tutorial.GROW_FACTOR = 3
Tutorial.GROW_MIN = 300
--- "attack": passed over when nobody borders the player this long after the step began.
Tutorial.CONTACT_WAIT_S = 25
--- The Attack bar's step asks for one stop of it, RATIO_GOAL (the next one up from where the bar
--- starts), left there for RATIO_HOLD_S: one tap on the stop the mark points at. Never more: since
--- 2026-10-04 the tutorial never encourages a 100% attack (an attack with everything leaves the
--- nation empty). Above RATIO_HIGH the card says to go back.
---   * Until 2026-10-08 it asked for 27% to 45% of a slider that ran from 1% to 100%, held for half
---     a second: on a phone that was 17 px of a 96 px track. 19.4% of the players who reached the
---     step left on it, the most of any step (Tutorial funnel, 2026-10-07), so the
---     step was made easier.
---   * Nobody waits on it past RATIO_MAX_S (the other steps: STEP_MAX_S).
Tutorial.RATIO_GOAL = 0.35
Tutorial.RATIO_LOW = 0.3
Tutorial.RATIO_HIGH = 0.4
Tutorial.RATIO_HOLD_S = 0.2
Tutorial.RATIO_MAX_S = 30
Tutorial.RATIO_TOO_MUCH = "Too many! Tap 35%"
--- A step nobody finishes in this long is passed over (the player is never stuck on one).
Tutorial.STEP_MAX_S = 75
--- With no order for this long the pointer shows where to tap again.
Tutorial.NUDGE_S = 5

--- The steps, in order. `touch` / `desktop`: what the card says; `%s` is the neighbour's name.
Tutorial.STEPS = {
	{ id = "spawn", touch = "Tap the map to start your nation", desktop = "Click the map to start your nation" },
	{ id = "expand", touch = "Tap the land next to you to take it", desktop = "Click the land next to you to take it" },
	{
		id = "grow",
		touch = "Tap empty land to expand",
		desktop = "Click empty land to expand",
		wait = "Now let your troops refill",
		bar = true,
	},
	-- (the neighbour before the slider: a first attack at the slider's 20% leaves an army at home; in
	-- the first order of steps a new player dragged it to 100% and sent everything)
	{
		id = "attack",
		touch = "Tap %s, then tap again to attack",
		desktop = "Click %s's land to attack them",
	},
	{
		id = "ratio",
		touch = "Tap 35% below. Keep troops home!",
		desktop = "Click 35% on the Attack bar. Keep troops home!",
		max_s = Tutorial.RATIO_MAX_S,
	},
	{
		id = "city",
		touch = "Open BUILD, pick City, tap your land",
		desktop = "Pick City (1) and click your land",
		note = "Here is gold for your first City",
	},
}

--- The "Tutorial" funnel's steps (Creator Dashboard): 1 is the match starting, then one a step,
--- then finishing. A step passed over is not logged.
Tutorial.FUNNEL = { "Started", "Spawned", "First Tap", "Grew", "Attacked", "Used Slider", "Built City", "Completed" }

--- The funnel step of finishing step `id` (2..7), or nil.
function Tutorial.funnel_step(id: string): number?
	for i, s in Tutorial.STEPS do
		if s.id == id then
			return i + 1
		end
	end
	return nil
end

--- True for a player who has never played: no tutorial state, no match counted, no tip seen.
--- `ui` is the saved [ui] settings, `stats` the saved [stats] ({ matches }).
function Tutorial.is_new(ui: any, stats: any): boolean
	local u = if type(ui) == "table" then ui else {}
	local s = if type(stats) == "table" then stats else {}
	if type(u.tutorial) == "string" and u.tutorial ~= "" then
		return false
	end
	if (tonumber(s.matches) or 0) > 0 then
		return false
	end
	if type(u.tips_seen) == "table" and next(u.tips_seen) ~= nil then
		return false
	end
	return true
end

--- The land "grow" asks for, from the land the nation had when the step began.
function Tutorial.grow_goal(tiles: number): number
	return math.floor(math.max(tiles * Tutorial.GROW_FACTOR, tiles + Tutorial.GROW_MIN))
end

--- Where step `id` is in STEPS, or nil.
function Tutorial.step_index(id: string): number?
	for i, s in Tutorial.STEPS do
		if s.id == id then
			return i
		end
	end
	return nil
end

return Tutorial
