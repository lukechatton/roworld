--!strict
-- RoWorld General (2026-10-27): a monthly Roblox subscription, paid in Robux (Creator Dashboard ->
-- Monetization -> Subscriptions; Roblox renews and bills it, and players cancel it in Roblox's own
-- settings). A paying player spent 89 Robux on average against about 600 at the top 500
-- experiences (the week to 2026-10-26), and nothing they could buy came back every month. Every player
-- is greeted as Commander: a subscriber is a General. While subscribed (server/General):
--   * a crate every UTC day they play (Purchases.general_perks); where paid random items are
--     restricted (no crates there: PolicyService), DAILY_STARS Stars instead;
--   * +STARS_BONUS on every match's Stars, on top of 2x Stars (server/Rewards: the "general" line);
--   * the month's General skin (SKINS; Data/Cosmetics.general_skins), theirs to keep.
--
-- `ID` is the subscription's id ("EXP-..."; "" = not created yet: nothing offers it), `STAGING` the
-- same subscription in Rofront Staging. Prod's was created inactive (2026-10-27): activate it on the
-- dashboard when the build that offers it goes to prod.
local IS_ROBLOX = typeof(game) == "Instance"
local Staging: any = if IS_ROBLOX then require((script :: any).Parent.Staging) else (require :: any)("./Staging")

local Subscription = {}

Subscription.ID = "EXP-6347955979564483083"
Subscription.STAGING = "EXP-287838471589069369"
Subscription.NAME = "RoWorld General"
--- The price set on the dashboard (Robux a month); the interface shows Roblox's own.
Subscription.ROBUX = 399
Subscription.DAILY_STARS = 2500
Subscription.STARS_BONUS = 0.5
--- The General skin of each month ("YYYY-MM", UTC, oldest first): a month without its own gives the
--- latest one before it.
Subscription.SKINS = {
	{ month = "2026-10", skin = "gen_chevrons" },
}

--- The subscription's id in this experience ("" where there is none).
function Subscription.id(): string
	return if Staging.here() then Subscription.STAGING else Subscription.ID
end

--- The UTC day number of unix time `t`.
function Subscription.day(t: number): number
	return math.floor(t / 86400)
end

--- The General skin of the month of unix time `t`.
function Subscription.skin_for(t: number): string?
	local month = os.date("!%Y-%m", math.floor(t)) :: string
	local skin = nil
	for _, s in Subscription.SKINS do
		if s.month <= month then
			skin = s.skin
		end
	end
	return skin or (if #Subscription.SKINS > 0 then Subscription.SKINS[1].skin else nil)
end

--- What a match's Stars gain (`total` before 2x Stars) for a General: whole QUANTUMs.
function Subscription.bonus(total: number, quantum: number): number
	local q = math.max(quantum, 1)
	return math.floor(math.max(total, 0) * Subscription.STARS_BONUS / q) * q
end

return Subscription
