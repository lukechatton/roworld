--!strict
-- The starter pack (2026-10-15): Mega Nuke + Scattershot + 2x Stars for 39 Robux, a limited-time
-- offer (DURATION_S), once per account,
-- for a player who has never bought anything with Robux. Like Tribes' first Golden Drop offer
-- (~/roblox/tribes docs/economy.md), the deadline is real: the clock starts the first time the offer is
-- on the player's screen and runs DURATION_S; then it is gone for good, never restarted.
-- docs/arsenal.md "The starter pack"; the server's side is server/Purchases (starter_*).
local Starter = {}

--- Its developer product (Data/Products).
Starter.PRODUCT = "starter_pack"
--- What it unlocks (Data/Arsenal keys). One the player already has pays its Stars instead
--- (Purchases.DUPLICATE_STARS_PER_ROBUX for each Robux of that item's own price).
Starter.ITEMS = { "mega", "scatter", "stars2x" }
--- How long the offer runs once seen.
Starter.DURATION_S = 48 * 3600
--- A purchase still lands this long after the end (a prompt opened in time and paid late).
Starter.GRACE_S = 15 * 60
--- The offer opens by itself on the title at most this often per player (since 2026-10-17; before, it
--- opened on every server a player joined, and every public match ends on a new one, so 229,658 times
--- on 2026-10-16 for 91,572 players). The title's starter button always opens it.
Starter.AUTO_GAP_S = 6 * 3600

--- Whether the offer may open by itself now. `state`: the offer's ("ready" = never shown: always, its
--- clock starts then); `last`: os.time() of the last time it opened by itself (the player's saved
--- [ui] "starter_auto_at"; nil/0 = never); `now`: os.time(). A `last` in the future (the device's
--- clock went back) counts as never.
function Starter.auto_due(state: string?, last: number?, now: number): boolean
	if state == "ready" then
		return true
	end
	if state ~= "active" then
		return false
	end
	local l = tonumber(last) or 0
	if l <= 0 or l > now + 60 then
		return true
	end
	return now - l >= Starter.AUTO_GAP_S
end

return Starter
