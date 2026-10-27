--!strict
-- RoWorld General (Data/Subscription; 2026-10-27): who on this server is subscribed, and their perks.
-- Roblox says who is (MarketplaceService:GetUserSubscriptionStatusAsync), when they join and whenever
-- Players.UserSubscriptionStatusChanged fires for the subscription. A General gets the day's crate
-- and the month's skin (Purchases.general_perks) on joining, on subscribing, and at the first tick of
-- each new UTC day while they stay; and +Subscription.STARS_BONUS on every match's Stars
-- (Rewards: deps.general = General.active). The client hears OP.GENERAL: { on, given? }.
--
--   General.configure(deps)   { status = fn(player) -> boolean? (nil: Roblox didn't answer),
--                               perks = fn(player, day, skin) -> given? (nil: not stored),
--                               send = fn(player, state), now = fn() -> unix s,
--                               subscribed = fn(player)? (they just subscribed), log? }
--   General.joined(player)    PlayerAdded (yields)
--   General.changed(player)   UserSubscriptionStatusChanged for this subscription (yields)
--   General.active(player) -> boolean
--   General.state(player) -> { on }   for a client that says HELLO
--   General.tick()            about once a minute (yields)
--   General.release(player)   PlayerRemoving
local IS_ROBLOX = typeof(game) == "Instance"
local Subscription: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Subscription)
	else require("../shared/Data/Subscription")

local General = {}

--- Asking Roblox whether a player is subscribed: attempts, and the wait between them (s).
General.STATUS_ATTEMPTS = 3
General.STATUS_WAIT_S = 2

--- on: subscribed; day: the UTC day whose perks were given this session
type Entry = { on: boolean, day: number? }

local deps: { [string]: any } = {}
local entries: { [any]: Entry } = {}

function General.configure(d: { [string]: any })
	for k, v in d do
		deps[k] = v
	end
end

--- Tests: forget everyone.
function General.reset()
	table.clear(entries)
end

local function now(): number
	return if deps.now then deps.now() else os.time()
end

local function send(player: any, state: any)
	if deps.send then
		pcall(deps.send, player, state)
	end
end

--- Subscribed? Asked a few times; nil when Roblox never answered.
local function status(player: any): boolean?
	for i = 1, General.STATUS_ATTEMPTS do
		local ok, on = pcall(deps.status, player)
		if ok and type(on) == "boolean" then
			return on
		end
		if i < General.STATUS_ATTEMPTS and IS_ROBLOX then
			task.wait(General.STATUS_WAIT_S)
		end
	end
	if deps.log then
		deps.log("[General] no subscription status for " .. tostring(player.UserId))
	end
	return nil
end

--- The day's perks for a General, once a day (a failed store is tried again at the next tick).
local function perks(player: any, e: Entry)
	local t = now()
	local day = Subscription.day(t)
	if not e.on or e.day == day then
		return
	end
	local ok, given = pcall(deps.perks, player, day, Subscription.skin_for(t))
	if ok and given ~= nil then
		e.day = day
		if next(given) ~= nil then
			send(player, { on = true, given = given })
		end
	end
end

function General.joined(player: any)
	if Subscription.id() == "" or deps.status == nil then
		return
	end
	local on = status(player)
	if entries[player] ~= nil or (IS_ROBLOX and player.Parent == nil) then
		return -- (changed() got there first, or they left while Roblox answered)
	end
	local e: Entry = { on = on == true }
	entries[player] = e
	send(player, { on = e.on })
	perks(player, e)
end

function General.changed(player: any)
	if Subscription.id() == "" or deps.status == nil then
		return
	end
	local on = status(player)
	if on == nil then
		return
	end
	local e = entries[player]
	if e == nil then
		e = { on = false }
		entries[player] = e
	end
	if e.on ~= on then
		e.on = on
		if on and deps.subscribed then
			pcall(deps.subscribed, player)
		end
		if deps.log then
			deps.log(
				string.format(
					"[General] %s %s",
					tostring(player.UserId),
					if on then "subscribed" else "is no longer subscribed"
				)
			)
		end
		send(player, { on = on })
	end
	perks(player, e)
end

function General.active(player: any): boolean
	local e = entries[player]
	return e ~= nil and e.on
end

function General.state(player: any): any
	return { on = General.active(player) }
end

function General.tick()
	for player, e in entries do
		if e.on then
			perks(player, e)
		end
	end
end

function General.release(player: any)
	entries[player] = nil
end

return General
