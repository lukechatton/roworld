--!strict
-- Robux purchases (developer products, shared/Data/Products). A purchase is a saved credit: Roblox's
-- ProcessReceipt adds it to the player's record in its own DataStore (only the server writes it —
-- the client's SETTING op can't touch it) and only then reports the purchase granted, so Roblox
-- retries until it is stored and a receipt is never granted twice (its PurchaseId is kept). The game
-- spends a credit when the moment comes (Purchases.use); one bought after the moment passed stays
-- for the next time.
--
--   Purchases.configure(deps)     { datastore = DataStore, notify = fn(player, credits), log?, warn?,
--                                   arrived? = fn(player) -> { p = record? }? }
--   Purchases.process_receipt(info) -> "granted" | "not_processed"   (a product's `count` credits)
--   Purchases.load(player)        read the record (join; retried while Roblox refuses it), or take the
--                                 one the last server handed on (deps.arrived: server/Handoff); notify
--   Purchases.credits(player) -> { [kind]: number }
--   Purchases.use(player, kind) -> (ok, err?)   spend one (yields)
--   Purchases.settle(player, max_s) -> record?  leaving for another server: the record once this
--                                 server's writes have landed (yields)
--   Purchases.release(player)     PlayerRemoving
--   Purchases.lost                { payouts, stars } that could not be paid after every retry
--   Purchases.open_crate(player) -> (ok, item_id | err)   spend a crate credit, roll (never a duplicate)
--   Purchases.equip(player, slot, id | false) -> (ok, err?)   "skin" / "flag"; only owned items
--   Purchases.inventory(player) -> { owned = { id }, equipped = { skin?, flag? }, crates_bought,
--                                    stars, unlocks = { key } }
--   Purchases.add_stars(player, amount) -> (ok, balance)   a match's Stars (Data/Stars; yields)
--   Purchases.buy_unlock(player, key) -> (ok, err?)        unlock an Arsenal item with Stars (yields)
--   Purchases.has_unlock(player, key) / Purchases.unlock_mask(player)   what the player has unlocked
--   Purchases.starter_state(player) -> false | { state = "ready" } | { state = "active", left = s }
--   Purchases.starter_seen(player)   the starter pack is on their screen: its clock starts (once; yields)
--   Purchases.general_perks(player, day, skin, crates) -> given?   a RoWorld General's day (yields)
-- The Arsenal (Data/Arsenal): a product whose `grants` is "unlock:<key>" is not a credit — its receipt
-- unlocks that item for good (and pays the item's bonus Stars once). The same unlock bought twice (the
-- shop never offers it) pays Stars instead, DUPLICATE_STARS_PER_ROBUX for each Robux of its price.
-- The starter pack (Data/Starter; 2026-10-15): one product, kind "starter", that unlocks
-- Starter.ITEMS, for a player who has never paid Robux. Its record `starter` = { started, ends, used? }
-- is made the first time the offer is on their screen (starter_seen) and never again: a real deadline.
-- Its receipt is refused (not granted, never stored) unless that offer is running or ended under
-- Starter.GRACE_S ago and wasn't used: a prompt for it opened any other way buys nothing.
-- The record: { credits = { kind = n }, receipts = { id }, owned = { [item] = true },
--   equipped = { skin = id?, flag = id? }, crates_bought = n, stars = n, stars_earned = n,
--   unlocks = { [key] = true }, paid = bool, starter = { started, ends, used? }?, gifts = { [item] = true } }.
-- The flag shop (Data/Shop; 2026-10-22): a product whose `grants` is "shopflag:<key>" adds that
-- flag (item "shop_<key>") and puts it on, whenever its receipt comes (the shop may have turned over
-- since the prompt opened). One already owned pays Stars instead, as a second Arsenal unlock does.
-- A set's bundle ("shopset:<id>", 2026-10-24) adds every flag of the set and wears its rarest new
-- one (unless one of the set is worn already); a flag owned before pays its share of the bundle's price
-- in Stars.
-- Exclusive cosmetics (Cosmetics.exclusive_skins, made for particular players): every read of a
-- record for a player (clean(v, user_id)) owns what Cosmetics.granted(user_id) lists, and the first
-- time (not yet in `gifts`) puts it on; nobody else's record can hold one.
local IS_ROBLOX = typeof(game) == "Instance"
local Products: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Products)
	else require("../shared/Data/Products")
local Cosmetics: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Cosmetics)
	else require("../shared/Data/Cosmetics")
local Arsenal: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Arsenal)
	else require("../shared/Data/Arsenal")
local Starter: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Starter)
	else require("../shared/Data/Starter")
local Shop: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Shop)
	else require("../shared/Data/Shop")
local Subscription: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Subscription)
	else require("../shared/Data/Subscription")

local Purchases = {}

Purchases.STORE = "RofrontPurchases_v1"
--- Receipts remembered per player (a retried ProcessReceipt is always about a recent one).
Purchases.RECEIPTS_KEPT = 100
Purchases.MAX_CREDITS = 1000
Purchases.MAX_STARS = 1000000000
--- Stars for each Robux of an unlock bought a second time (what an Arsenal price works out to).
Purchases.DUPLICATE_STARS_PER_ROBUX = 500

type Record = {
	credits: { [string]: number },
	receipts: { string },
	owned: { [string]: boolean },
	equipped: { skin: string?, flag: string? },
	crates_bought: number,
	stars: number,
	stars_earned: number,
	unlocks: { [string]: boolean },
	--- the tutorial's Stars were paid (Data/Tutorial.STARS, once per player)
	tutorial_paid: boolean?,
	--- ever paid Robux (a record from before this field: it has receipts)
	paid: boolean,
	--- the starter pack's offer, once it has been on their screen
	starter: { started: number, ends: number, used: boolean? }?,
	--- exclusive items already given (and put on once): Cosmetics.granted
	gifts: { [string]: boolean },
	--- RoWorld General: the UTC day whose perks were given (Purchases.general_perks)
	general_day: number?,
	--- the ids of the last PAYOUTS_KEPT Stars payouts stored (a payout tried again is stored once)
	payouts: { string },
}

--- Reading a player's record when they join: GetAsync attempts and the waits between them. Roblox
--- throttles DataStore reads now and then ("TooManyRequests ... API: GetAsync", 37 in a day on the
--- error report of 2026-10-05). The load used to give up after one attempt, and that player then
--- had none of their unlocks, Stars or cosmetics for the whole session.
Purchases.LOAD_ATTEMPTS = 5
Purchases.LOAD_BACKOFF = { 1, 3, 6, 10 }
--- After those the session goes on without the record, and the read is tried again every
--- LOAD_RETRY_S, LOAD_RETRIES more times, while the player stays.
Purchases.LOAD_RETRY_S = 20
Purchases.LOAD_RETRIES = 30
--- Stars that could not be paid at all: owed (below), and then not even kept in MemoryStore.
Purchases.lost = { payouts = 0, stars = 0 }
--- Stars payouts whose write failed are owed, not lost (2026-11-13: since Nov 10 Roblox refused so
--- many writes to the Purchases store that 50,000-97,000 match payouts a day failed every retry and
--- were dropped). An owed payout keeps its id and goes with the player's next write to their record
--- (any write: a crate, an equip, the next payout), is tried again over OWED_RETRY_S while they stay,
--- and is kept in MemoryStore when they leave (deps.owed_map, OWED_HOLD_S): the next server they join
--- pays it. The record keeps the ids of its last PAYOUTS_KEPT payouts, so one is never stored twice.
Purchases.OWED_RETRY_S = { 15, 30, 60, 120 }
Purchases.OWED_HOLD_S = 45 * 24 * 3600
Purchases.PAYOUTS_KEPT = 50
--- One write at a time to a record from this server: a second write to the same key within Roblox's
--- cooldown waits in Roblox's queue, and a full queue (30) drops every other player's writes too (the
--- error report's "DataStore request was added to queue ... Key = u<player>"). A write waits at most
--- this long for the one before it.
Purchases.KEY_WAIT_S = 30
--- Counts for the server's report (Purchases.take_stats).
Purchases.stats = { payouts = 0, owed_new = 0, owed_paid = 0, owed_kept = 0, writes = 0, write_fails = 0, skipped = 0 }

local deps: { [string]: any } = {}
local cache: { [any]: { [string]: number } } = {}
--- the player's items (the record's owned / equipped / crates_bought), as last read or written
local inv: { [any]: any } = {}
--- player -> the load that is still trying to read their record (a token: a newer load, a write
--- that brought the record, or leaving ends it)
local loading: { [any]: any } = {}
--- player -> their whole record as last read or written (handed to the next server: Purchases.settle)
local records: { [any]: Record } = {}
--- user id -> this server's writes to their record still in flight
local busy: { [number]: number } = {}
--- user id -> a write failed since the record was last read or written: what this server holds may
--- not be what is stored (Purchases.use keeps a spend before it is stored)
local doubt: { [number]: boolean } = {}
--- user id -> Stars payouts not stored yet: { id, stars, tutorial?, m? (also in MemoryStore) }
local owed: { [number]: { any } } = {}
--- user id -> a retry of their owed payouts is under way
local retrying: { [number]: boolean } = {}
--- user id -> writes to their record in this report's window (the most to one record is reported)
local key_writes: { [number]: number } = {}
--- players who left (a write landing after that doesn't bring their entry back)
local left: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
--- (defined after clean: the owed payouts folded into a record)
local fold_owed: (any, number, { any }) -> any

--- What is left of `list` without the entries whose ids are in `ids`.
local function without(list: { any }?, ids: { [string]: boolean }): { any }?
	if list == nil then
		return nil
	end
	local out = {}
	for _, e in list do
		if not ids[e.id] then
			table.insert(out, e)
		end
	end
	return if #out > 0 then out else nil
end

--- `entries` were stored: off the owed list, and out of MemoryStore for those that were kept there.
local function owed_stored(user_id: number, entries: { any })
	local ids: { [string]: boolean } = {}
	local kept: { [string]: boolean } = {}
	local any_kept = false
	for _, e in entries do
		ids[e.id] = true
		if e.late then
			Purchases.stats.owed_paid += 1
		end
		if e.m then
			kept[e.id] = true
			any_kept = true
		end
	end
	owed[user_id] = without(owed[user_id], ids)
	local map = deps.owed_map
	if any_kept and map ~= nil then
		local spawn = deps.spawn or task.spawn
		spawn(function()
			pcall(function()
				map:UpdateAsync("u" .. tostring(user_id), function(old: any): any
					return without(if type(old) == "table" then old else nil, kept) or {}
				end, Purchases.OWED_HOLD_S)
			end)
		end)
	end
end

--- Yields (at most `max_s`, and only with deps.wait) while a write to `user_id`'s record is in flight.
local function writes_done(user_id: number, max_s: number)
	local waited = 0
	while busy[user_id] ~= nil and deps.wait ~= nil and waited < max_s do
		waited += 0.1
		deps.wait(0.1)
	end
end

--- Every write to a record: UpdateAsync on its key, one at a time per record from this server, counted
--- while in flight, and carrying the player's owed payouts. Errors as UpdateAsync does.
local function update(user_id: number, fn: (any) -> any): any
	if deps.wait ~= nil then
		local waited = 0
		while busy[user_id] ~= nil and waited < Purchases.KEY_WAIT_S do
			waited += 0.05
			deps.wait(0.05)
		end
	end
	busy[user_id] = (busy[user_id] or 0) + 1
	Purchases.stats.writes += 1
	key_writes[user_id] = (key_writes[user_id] or 0) + 1
	local due = owed[user_id]
	local pending = if due ~= nil and #due > 0 then table.clone(due) else nil
	local transform = fn
	if pending ~= nil then
		transform = function(old: any): any
			local base = fold_owed(old, user_id, pending)
			local v = fn(if base ~= nil then base else old)
			if v ~= nil then
				return v
			end
			return base
		end
	end
	local ok, res = pcall(function()
		return deps.datastore:UpdateAsync("u" .. tostring(user_id), transform)
	end)
	local n = (busy[user_id] or 1) - 1
	busy[user_id] = if n > 0 then n else nil
	if not ok then
		Purchases.stats.write_fails += 1
		doubt[user_id] = true
		error(res, 0)
	end
	doubt[user_id] = nil
	if pending ~= nil then
		owed_stored(user_id, pending)
	end
	return res
end

--- Stars owed to the player (not stored yet), for what they are shown.
local function owed_stars(user_id: number): number
	local n = 0
	for _, e in owed[user_id] or {} do
		n += e.stars
	end
	return n
end

--- A payout's id: unique enough within one player's last PAYOUTS_KEPT.
local function new_id(): string
	return string.format("%06x%06x", math.random(0, 0xFFFFFF), math.random(0, 0xFFFFFF))
end

function Purchases.configure(d: { [string]: any })
	for k, v in d do
		deps[k] = v
	end
end

--- Tests: forget everyone.
function Purchases.reset()
	table.clear(cache)
	table.clear(inv)
	table.clear(loading)
	table.clear(records)
	table.clear(busy)
	table.clear(doubt)
	table.clear(owed)
	table.clear(retrying)
	table.clear(key_writes)
	table.clear(left)
	Purchases.lost.payouts = 0
	Purchases.lost.stars = 0
	for k in Purchases.stats do
		Purchases.stats[k] = 0
	end
end

--- The credit kind a product grants (nil: not ours), and how many of it (the 3-crate pack: 3).
function Purchases.kind_of(product_id: number): (string?, number)
	for kind, p in Products do
		if p.id ~= 0 and p.id == product_id then
			return p.grants or kind, math.clamp(math.floor(tonumber(p.count) or 1), 1, 10)
		end
	end
	return nil, 0
end

local function key(user_id: number): string
	return "u" .. tostring(user_id)
end

local function clean(v: any, user_id: number?): Record
	local rec: Record = {
		credits = {},
		receipts = {},
		owned = {},
		equipped = {},
		crates_bought = 0,
		stars = 0,
		stars_earned = 0,
		unlocks = {},
		paid = false,
		gifts = {},
		payouts = {},
	}
	if type(v) ~= "table" then
		v = {}
	end
	local function count(x: any): number
		local n = tonumber(x) or 0
		return if n ~= n then 0 else math.clamp(math.floor(n), 0, Purchases.MAX_STARS)
	end
	rec.stars = count(v.stars)
	rec.stars_earned = count(v.stars_earned)
	rec.tutorial_paid = if v.tutorial_paid == true then true else nil
	local gday = tonumber(v.general_day)
	rec.general_day = if gday ~= nil and gday == gday then math.floor(gday) else nil
	if type(v.unlocks) == "table" then
		for k, on in v.unlocks do
			if on == true and Arsenal.item(k) ~= nil then
				rec.unlocks[k] = true
			end
		end
	end
	if type(v.owned) == "table" then
		for id, on in v.owned do
			if on == true and Cosmetics.may_own(id, user_id) then
				rec.owned[id] = true
			end
		end
	end
	if type(v.gifts) == "table" then
		for id, on in v.gifts do
			if on == true and type(id) == "string" then
				rec.gifts[id] = true
			end
		end
	end
	if type(v.equipped) == "table" then
		for _, slot in { "skin", "flag" } do
			local id = v.equipped[slot]
			local it = Cosmetics.item(id)
			if it ~= nil and it.kind == slot and rec.owned[id] then
				rec.equipped[slot] = id
			end
		end
	end
	-- (made for this player: always owned; worn the first time, then their own choice)
	for _, id in Cosmetics.granted(user_id) do
		local it = Cosmetics.item(id)
		if it ~= nil then
			rec.owned[id] = true
			if not rec.gifts[id] then
				rec.gifts[id] = true
				rec.equipped[it.kind] = id
			end
		end
	end
	rec.crates_bought = math.max(0, math.floor(tonumber(v.crates_bought) or 0))
	if type(v.payouts) == "table" then
		for _, id in v.payouts do
			if type(id) == "string" and #id <= 24 then
				table.insert(rec.payouts, id)
			end
		end
	end
	if type(v.credits) == "table" then
		for k, n in v.credits do
			if type(k) == "string" and type(n) == "number" and n == n then
				rec.credits[k] = math.clamp(math.floor(n), 0, Purchases.MAX_CREDITS)
			end
		end
	end
	if type(v.receipts) == "table" then
		for _, r in v.receipts do
			if type(r) == "string" then
				table.insert(rec.receipts, r)
			end
		end
	end
	-- (a stored `paid` wins: Staging's "Replay as new player" sets it false with receipts kept)
	rec.paid = if type(v.paid) == "boolean" then v.paid else #rec.receipts > 0
	if type(v.starter) == "table" then
		local started, ends = tonumber(v.starter.started), tonumber(v.starter.ends)
		if started ~= nil and ends ~= nil and started == started and ends == ends then
			rec.starter = { started = started, ends = ends, used = if v.starter.used == true then true else nil }
		end
	end
	return rec
end

--- The record `old` with the owed payouts `entries` stored on it (each once: its id is kept), or nil
--- when every one of them is stored already. A tutorial's Stars are paid once whatever the id.
fold_owed = function(old: any, user_id: number, entries: { any }): any
	local rec = clean(old, user_id)
	local changed = false
	for _, e in entries do
		-- (the tutorial's Stars come once, whatever their id)
		if not table.find(rec.payouts, e.id) and not (e.tutorial and rec.tutorial_paid) then
			rec.stars = math.min(rec.stars + e.stars, Purchases.MAX_STARS)
			rec.stars_earned = math.min(rec.stars_earned + e.stars, Purchases.MAX_STARS)
			if e.tutorial then
				rec.tutorial_paid = true
			end
			table.insert(rec.payouts, e.id)
			changed = true
		end
	end
	while #rec.payouts > Purchases.PAYOUTS_KEPT do
		table.remove(rec.payouts, 1)
	end
	return if changed then rec else nil
end

local function log(text: string)
	if deps.log then
		deps.log("[Purchases] " .. text)
	end
end

local function player_by_id(user_id: number): any
	local ps = deps.players
	if ps == nil then
		return nil
	end
	local ok, p = pcall(function()
		return ps:GetPlayerByUserId(user_id)
	end)
	return if ok then p else nil
end

local function remember(player: any, rec: Record)
	if left[player] then
		return -- (a write that landed after they left)
	end
	loading[player] = nil -- (the record is here: a load still retrying has nothing left to do)
	records[player] = rec
	cache[player] = rec.credits
	inv[player] = {
		owned = rec.owned,
		equipped = rec.equipped,
		crates_bought = rec.crates_bought,
		stars = rec.stars,
		stars_earned = rec.stars_earned,
		unlocks = rec.unlocks,
		paid = rec.paid,
		starter = rec.starter,
	}
end

--- The record to judge a request by without writing (2026-11-13: v117's servers showed one record
--- written ~118 times a minute, the 2-a-second cap on a player's crate / credit / unlock requests, and
--- every one wrote even with nothing to spend). The record as last read or written, when nothing can
--- have changed it meanwhile: loaded, no write of ours in flight (a purchase landing) or in doubt.
--- Nil: write, and judge inside the write.
local function settled_record(player: any): Record?
	local uid = player.UserId
	if loading[player] ~= nil or busy[uid] ~= nil or doubt[uid] then
		return nil
	end
	return records[player]
end

local function now_s(): number
	return if type(deps.now) == "function" then deps.now() else os.time()
end

--- The starter pack's product exists here (Studio: always, its prompt is a test purchase).
local function starter_on_sale(): boolean
	local p = Products[Starter.PRODUCT]
	return p ~= nil and (p.id ~= 0 or deps.studio == true)
end

--- `r` (a record, or a player's inv entry) has every item the pack unlocks.
local function starter_all_owned(r: any): boolean
	for _, k in Starter.ITEMS do
		if not r.unlocks[k] then
			return false
		end
	end
	return true
end

--- `r` may be offered the pack for the first time: never paid Robux, has played (a match or the
--- tutorial paid Stars), and doesn't have all of it already.
local function starter_eligible(r: any): boolean
	return not r.paid and (r.stars_earned or 0) > 0 and not starter_all_owned(r)
end

--- The pack's receipt may be granted on record `rec` at time `t`.
local function starter_redeemable(rec: Record, t: number): boolean
	local s = rec.starter
	return s ~= nil and not s.used and t <= s.ends + Starter.GRACE_S
end

--- Unlocks Arsenal item `it` on `rec` (a Robux receipt, or Stars already taken): its bonus Stars come
--- with it once. Already unlocked: Stars for the price instead.
local function unlock_on(rec: Record, it: any, robux: number?)
	if rec.unlocks[it.key] then
		local back = math.floor((robux or 0) * Purchases.DUPLICATE_STARS_PER_ROBUX)
		rec.stars = math.min(rec.stars + back, Purchases.MAX_STARS)
		return
	end
	rec.unlocks[it.key] = true
	rec.stars = math.min(rec.stars + (it.bonus or 0), Purchases.MAX_STARS)
end

local function notify(player: any)
	if player ~= nil and deps.notify then
		pcall(deps.notify, player, table.clone(cache[player] or {}))
	end
	if player ~= nil and deps.inventory then
		pcall(deps.inventory, player, Purchases.inventory(player))
	end
end

--- The player's items for the client: owned ids (list), equipped, crates bought.
function Purchases.inventory(player: any): any
	local i = inv[player]
	local owned = {}
	if i ~= nil then
		for id in i.owned do
			table.insert(owned, id)
		end
		table.sort(owned)
	end
	local unlocks = {}
	if i ~= nil then
		for k in i.unlocks do
			table.insert(unlocks, k)
		end
		table.sort(unlocks)
	end
	return {
		owned = owned,
		equipped = if i ~= nil then table.clone(i.equipped) else {},
		crates_bought = if i ~= nil then i.crates_bought else 0,
		-- (with Stars owed: paid, not stored yet)
		stars = (if i ~= nil then i.stars else 0) + owed_stars(player.UserId),
		unlocks = unlocks,
		starter = Purchases.starter_state(player),
	}
end

--- The starter pack for this player: false (none: not eligible, bought, ended, or not on sale here),
--- { state = "ready" } (never shown yet: the client shows it and says so, starter_seen), or
--- { state = "active", left = seconds } (its clock is running).
function Purchases.starter_state(player: any): any
	local i = inv[player]
	if i == nil or not starter_on_sale() or starter_all_owned(i) then
		return false
	end
	local s = i.starter
	if s ~= nil then
		local left = s.ends - now_s()
		if s.used or left <= 0 then
			return false
		end
		return { state = "active", left = left }
	end
	return if starter_eligible(i) then { state = "ready" } else false
end

--- The offer is on the player's screen: its clock starts, once (a no-op when it already ran or they
--- can't have it). Yields. True when the clock started now.
function Purchases.starter_seen(player: any): boolean
	if not starter_on_sale() then
		return false
	end
	local known = records[player]
	if known ~= nil and (known.starter ~= nil or not starter_eligible(known)) then
		Purchases.stats.skipped += 1
		return false -- (started before, or not for them: nothing to write)
	end
	local started = false
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			started = false
			local rec = clean(old, player.UserId)
			stored = rec
			if rec.starter ~= nil or not starter_eligible(rec) then
				return nil
			end
			local t = now_s()
			rec.starter = { started = t, ends = t + Starter.DURATION_S }
			started = true
			return rec
		end)
	end)
	if not ok or stored == nil then
		log("could not start the starter pack for " .. tostring(player.UserId) .. ": " .. tostring(err))
		return false
	end
	remember(player, stored :: Record)
	notify(player)
	return started
end

--- True when the player has Arsenal item `key` (as last read or written).
function Purchases.has_unlock(player: any, key: string): boolean
	local i = inv[player]
	return i ~= nil and i.unlocks[key] == true
end

--- The player's Arsenal as the Sim's bit mask (Defs.UNLOCK; Sim.set_unlocks).
function Purchases.unlock_mask(player: any): number
	local i = inv[player]
	return if i ~= nil then Arsenal.mask(i.unlocks) else 0
end

--- The player's Stars, with those owed (paid, not stored yet).
function Purchases.stars(player: any): number
	local i = inv[player]
	return (if i ~= nil then i.stars else 0) + owed_stars(player.UserId)
end

--- What the player shows in a match: { skin = id?, flag = id? } (nil when nothing is equipped).
function Purchases.equipped(player: any): any
	local i = inv[player]
	if i == nil or (i.equipped.skin == nil and i.equipped.flag == nil) then
		return nil
	end
	return table.clone(i.equipped)
end

--- Roblox's ProcessReceipt: store the credit, then say granted (never before it is stored).
function Purchases.process_receipt(info: any): string
	local user_id = tonumber(info and info.PlayerId)
	local product = tonumber(info and info.ProductId)
	local receipt = if info and type(info.PurchaseId) == "string" then info.PurchaseId else nil
	local kind, n = nil, 1
	if product then
		kind, n = Purchases.kind_of(product)
	end
	if user_id == nil or kind == nil or receipt == nil then
		log("unknown receipt for product " .. tostring(product))
		return "not_processed"
	end
	return Purchases.grant(user_id, kind, receipt, n, tonumber(info.CurrencySpent))
end

--- Store `n` (default 1) `kind` credits for `user_id` under `receipt` (once per receipt). "granted" once
--- stored. `spent`: the Robux the receipt says were paid (Managed Pricing: not always the set price),
--- passed on to deps.bought.
function Purchases.grant(user_id: number, kind: string, receipt: string, n: number?, spent: number?): string
	local count = math.clamp(math.floor(n or 1), 1, 10)
	local stored: Record? = nil
	local refused = false
	local ok, err = pcall(function()
		update(user_id, function(old: any): any
			refused = false
			local rec = clean(old, user_id)
			if table.find(rec.receipts, receipt) then
				stored = rec -- granted before (a retry): nothing to add
				return nil
			end
			local unlock_key = string.match(kind, "^unlock:(.+)$")
			local it = if unlock_key ~= nil then Arsenal.item(unlock_key) else nil
			local shop_key = string.match(kind, "^shopflag:(.+)$")
			local set_id = string.match(kind, "^shopset:(.+)$")
			if set_id ~= nil then
				local keys = Shop.set_keys(set_id)
				local total = Shop.set_total(set_id)
				local p = Products["shopset_" .. set_id]
				local paid = if p ~= nil then p.robux else 0
				local wear: string? = nil
				for _, k in keys do
					local id = Shop.item_id(k)
					if rec.owned[id] then
						local share = if total > 0 then paid * Shop.price(Shop.flag(k)) / total else 0
						rec.stars = math.min(rec.stars + math.floor(share * Purchases.DUPLICATE_STARS_PER_ROBUX), Purchases.MAX_STARS)
					else
						rec.owned[id] = true
						wear = wear or id -- (the keys come rarest first)
					end
				end
				if #keys == 0 then
					rec.stars = math.min(rec.stars + math.floor(paid * Purchases.DUPLICATE_STARS_PER_ROBUX), Purchases.MAX_STARS)
				end
				local worn = Shop.key_of(rec.equipped.flag)
				local worn_set = if worn ~= nil then (Shop.flag(worn) :: any).set else nil
				if wear ~= nil and worn_set ~= set_id then
					rec.equipped.flag = wear
				end
			elseif shop_key ~= nil then
				local id = Shop.item_id(shop_key)
				if Shop.flag(shop_key) == nil or rec.owned[id] then
					-- (owned already, or a flag this build doesn't know: Stars for the price)
					local p = Products["shop_" .. shop_key]
					local back = math.floor((if p ~= nil then p.robux else 0) * Purchases.DUPLICATE_STARS_PER_ROBUX)
					rec.stars = math.min(rec.stars + back, Purchases.MAX_STARS)
				else
					rec.owned[id] = true
					rec.equipped.flag = id -- (chosen and paid for: worn at once)
				end
			elseif kind == "starter" then
				local t = now_s()
				if not starter_redeemable(rec, t) then
					refused = true
					return nil
				end
				for _, k in Starter.ITEMS do
					local item = Arsenal.item(k)
					if item ~= nil then
						local p = Products[item.product]
						unlock_on(rec, item, if p ~= nil then p.robux else 0)
					end
				end
				local s = rec.starter :: any
				s.used = true
				s.bought = t
			elseif it ~= nil then
				local p = Products[it.product]
				unlock_on(rec, it, if p ~= nil then p.robux else 0)
			else
				rec.credits[kind] = math.min((rec.credits[kind] or 0) + count, Purchases.MAX_CREDITS)
				if kind == "crate" then
					rec.crates_bought += count
				end
			end
			table.insert(rec.receipts, receipt)
			while #rec.receipts > Purchases.RECEIPTS_KEPT do
				table.remove(rec.receipts, 1)
			end
			rec.paid = true
			stored = rec
			return rec
		end)
	end)
	if ok and refused then
		log(string.format("refused starter pack %s for %d: no running offer", receipt, user_id))
		return "not_processed"
	end
	if not ok or stored == nil then
		log("could not store receipt " .. receipt .. ": " .. tostring(err))
		return "not_processed"
	end
	local player = player_by_id(user_id)
	if player ~= nil then
		remember(player, stored :: Record)
		notify(player)
		if deps.bought then
			pcall(deps.bought, player, kind, count, spent)
		end
		local unlocked = if kind == "starter" then "" else string.match(kind, "^unlock:(.+)$")
		if unlocked ~= nil and deps.unlocked then
			pcall(deps.unlocked, player, unlocked)
		end
	end
	log(string.format("granted %s%s to %d (%s)", kind, if count > 1 then " x" .. count else "", user_id, receipt))
	return "granted"
end

--- What a write error was, in a word (for the warning the error report counts).
local function reason(err: any): string
	local text = tostring(err)
	for _, word in { "TooManyRequests", "InternalServerError", "ServiceUnavailable", "Throttled", "queue was full" } do
		if string.find(text, word, 1, true) then
			return word
		end
	end
	return "other"
end

--- Owed Stars that could not even be kept for later (MemoryStore refused them): lost. The server log has
--- who and how many; the warning is worded the same each time so the error report counts them.
local function stars_lost(user_id: number, amount: number, what: string, err: any)
	Purchases.lost.payouts += 1
	Purchases.lost.stars += amount
	log(string.format("could not pay %d %s Stars to %d: %s", amount, what, user_id, tostring(err)))
	if deps.warn then
		deps.warn(string.format("[Purchases] %s Stars lost after every retry (%s)", what, reason(err)))
	end
end

local function spawn_fn(): any
	return deps.spawn or (if IS_ROBLOX then task.spawn else nil)
end

--- One write that stores the player's owed payouts (update carries them). True when none are left.
local function pay_owed(player: any): boolean
	local uid = player.UserId
	if owed[uid] == nil then
		return true
	end
	local stored: Record? = nil
	local ok = pcall(function()
		update(uid, function(old: any): any
			stored = clean(old, uid)
			return nil
		end)
	end)
	if ok and stored ~= nil then
		remember(player, stored :: Record)
		notify(player)
	end
	return owed[uid] == nil
end

--- Tries the owed payouts again over OWED_RETRY_S while the player is here (until they are stored, or
--- the player leaves: their owed Stars go with them, Purchases.leave_owed).
local function retry_owed(player: any)
	local uid = player.UserId
	local spawn = spawn_fn()
	if retrying[uid] or deps.wait == nil or spawn == nil then
		return
	end
	retrying[uid] = true
	spawn(function()
		local i = 0
		while owed[uid] ~= nil do
			i += 1
			deps.wait(Purchases.OWED_RETRY_S[math.min(i, #Purchases.OWED_RETRY_S)])
			if owed[uid] == nil or left[player] then
				break
			end
			pay_owed(player)
		end
		retrying[uid] = nil
	end)
end

--- A joining player's owed Stars kept in MemoryStore by the server they left: owed here (and paid).
local function collect_owed(player: any)
	local map = deps.owed_map
	if map == nil then
		return
	end
	local uid = player.UserId
	local ok, v = pcall(function()
		return map:GetAsync("u" .. tostring(uid))
	end)
	if not ok or type(v) ~= "table" or left[player] then
		return
	end
	local list = owed[uid] or {}
	local have: { [string]: boolean } = {}
	for _, e in list do
		have[e.id] = true
	end
	for _, e in v do
		local n = if type(e) == "table" then math.floor(tonumber(e.stars) or 0) else 0
		if type(e) == "table" and type(e.id) == "string" and #e.id <= 24 and not have[e.id] and n > 0 and n <= 1000000 then
			table.insert(list, { id = e.id, stars = n, tutorial = if e.tutorial == true then true else nil, m = true, late = true })
			have[e.id] = true
		end
	end
	if #list == 0 then
		return
	end
	owed[uid] = list
	notify(player)
	if not pay_owed(player) then
		retry_owed(player)
	end
end

--- Yields: LOAD_ATTEMPTS reads with LOAD_BACKOFF between them, then, with the session already going
--- on an empty record, more every LOAD_RETRY_S (deps.wait; without one, a single attempt).
--- A player teleported here by a server of ours comes with the record that server held when they left
--- (deps.arrived: server/Handoff); then nothing is read.
function Purchases.load(player: any)
	local token = {}
	left[player] = nil
	loading[player] = token
	local got: any = nil
	if deps.arrived then
		local ok, g = pcall(deps.arrived, player)
		got = if ok and type(g) == "table" then g else nil
		if loading[player] ~= token then
			return
		end
	end
	-- Stars owed from an earlier server: kept in MemoryStore (a handoff says whether there are any)
	local spawn = spawn_fn()
	if deps.owed_map ~= nil and spawn ~= nil and (got == nil or got.o == true) then
		spawn(collect_owed, player)
	end
	if got ~= nil and type(got.p) == "table" then
		remember(player, clean(got.p, player.UserId))
		notify(player)
		return
	end
	local wait = deps.wait
	local tries = 0
	while true do
		tries += 1
		local ok, v = pcall(function()
			return deps.datastore:GetAsync(key(player.UserId))
		end)
		if loading[player] ~= token then
			return -- (they left, a write brought the record, or another load began)
		end
		if ok then
			remember(player, clean(v, player.UserId))
			notify(player)
			if tries > Purchases.LOAD_ATTEMPTS and deps.unlocked then
				-- (it came late: the match they are in learns what they have unlocked)
				pcall(deps.unlocked, player, "")
			end
			return
		end
		local last = not wait or tries >= Purchases.LOAD_ATTEMPTS + Purchases.LOAD_RETRIES
		if tries == Purchases.LOAD_ATTEMPTS or (last and tries < Purchases.LOAD_ATTEMPTS) then
			cache[player] = cache[player] or {}
			log(
				"load failed for "
					.. tostring(player.UserId)
					.. ": "
					.. tostring(v)
					.. (if last then "" else " (trying again while they stay)")
			)
			notify(player)
		end
		if last then
			loading[player] = nil
			return
		end
		wait(if tries < Purchases.LOAD_ATTEMPTS then Purchases.LOAD_BACKOFF[tries] or 10 else Purchases.LOAD_RETRY_S)
	end
end

function Purchases.credits(player: any): { [string]: number }
	return table.clone(cache[player] or {})
end

--- Spend one `kind` credit (atomic on the stored record). Yields.
function Purchases.use(player: any, kind: string): (boolean, string?)
	if Products[kind] == nil then
		return false, "unknown product"
	end
	local known = settled_record(player)
	if known ~= nil and (known.credits[kind] or 0) <= 0 then
		Purchases.stats.skipped += 1
		return false, "no credit" -- (none to spend: nothing to write)
	end
	local spent = false
	local left: { [string]: number }? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			spent = false
			local rec = clean(old, player.UserId)
			left = rec.credits
			remember(player, rec)
			if (rec.credits[kind] or 0) <= 0 then
				return nil
			end
			rec.credits[kind] -= 1
			spent = true
			left = rec.credits
			return rec
		end)
	end)
	if not ok then
		return false, "store unavailable: " .. tostring(err)
	end
	if left ~= nil then
		cache[player] = left
	end
	notify(player)
	if not spent then
		return false, "no credit"
	end
	return true, nil
end

--- A player leaving: their owed Stars (if any) go to MemoryStore for the next server they join. Yields.
--- True when there were some and they were kept (a handoff tells the next server to look).
function Purchases.leave_owed(player: any): boolean
	local uid = player.UserId
	local entries = owed[uid]
	owed[uid] = nil
	if entries == nil then
		return false
	end
	local map = deps.owed_map
	local ok, err = false, "no MemoryStore"
	if map ~= nil then
		ok, err = pcall(function()
			map:UpdateAsync("u" .. tostring(uid), function(old: any): any
				local list = if type(old) == "table" then old else {}
				local have: { [string]: boolean } = {}
				for _, e in list do
					if type(e) == "table" then
						have[e.id] = true
					end
				end
				for _, e in entries do
					if not have[e.id] then
						table.insert(list, { id = e.id, stars = e.stars, tutorial = e.tutorial })
					end
				end
				return list
			end, Purchases.OWED_HOLD_S)
		end)
	end
	if ok then
		Purchases.stats.owed_kept += #entries
		return true
	end
	for _, e in entries do
		stars_lost(uid, e.stars, if e.tutorial then "tutorial" else "match", err)
	end
	return false
end

function Purchases.release(player: any)
	left[player] = true
	loading[player] = nil
	cache[player] = nil
	inv[player] = nil
	records[player] = nil
	doubt[player.UserId] = nil
	key_writes[player.UserId] = nil
	if owed[player.UserId] ~= nil then
		-- A payout's write may still be in flight (most often: they closed the game as their match
		-- ended). Wait for it, so only what it didn't store is kept for later: v117 kept 15 of its first
		-- 92 payouts that way though they were stored, and the next server showed them twice until its
		-- write. (A teleport of ours waited already: ServerMain settles before leave_owed.)
		local uid = player.UserId
		local function keep()
			writes_done(uid, Purchases.KEY_WAIT_S)
			Purchases.leave_owed(player)
		end
		local spawn = spawn_fn()
		if spawn ~= nil then
			spawn(keep)
		else
			keep()
		end
	end
end

--- This window's counts (and a fresh window): payouts, owed and stored late, kept for later, writes,
--- failed writes, writes skipped (nothing to change), and the most writes to one record.
function Purchases.take_stats(): { [string]: number }
	local out: { [string]: number } = table.clone(Purchases.stats)
	local most = 0
	for _, n in key_writes do
		most = math.max(most, n)
	end
	out.max_key = most
	out.lost = Purchases.lost.payouts
	out.lost_stars = Purchases.lost.stars
	for k in Purchases.stats do
		Purchases.stats[k] = 0
	end
	Purchases.lost.payouts, Purchases.lost.stars = 0, 0
	table.clear(key_writes)
	return out
end

--- A player leaving for another server of ours (server/Handoff): waits, at most `max_s`, for this
--- server's writes to their record to land (a match's Stars are often still being paid), then returns
--- the record as it now stands; nil when it isn't known for sure (never read, still loading, a write
--- that failed or hasn't landed): the next server reads the store. Yields. Call before release.
function Purchases.settle(player: any, max_s: number): any
	local uid = player.UserId
	writes_done(uid, max_s)
	if busy[uid] ~= nil or doubt[uid] or loading[player] ~= nil or inv[player] == nil then
		return nil
	end
	return records[player]
end

--- Open one crate: spend a crate credit and add an item the player doesn't own (Cosmetics.roll, the
--- published odds), in one write; the new item is equipped when its slot is empty. Yields.
--- (ok, item_id) or (false, "no crate" | "everything owned" | "store unavailable: ...").
function Purchases.open_crate(player: any): (boolean, string?)
	local known = settled_record(player)
	if known ~= nil then
		-- (nothing to write: no crate, or nothing left to roll)
		if (known.credits.crate or 0) <= 0 then
			Purchases.stats.skipped += 1
			return false, "no crate"
		end
		if Cosmetics.roll(known.owned, 0, 0) == nil then
			Purchases.stats.skipped += 1
			return false, "everything owned"
		end
	end
	local rng = deps.rng or Random.new()
	local got: string? = nil
	local why = "no crate"
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			got = nil
			local rec = clean(old, player.UserId)
			stored = rec
			if (rec.credits.crate or 0) <= 0 then
				why = "no crate"
				return nil
			end
			local id = Cosmetics.roll(rec.owned, rng:NextNumber(), rng:NextNumber())
			if id == nil then
				why = "everything owned"
				return nil
			end
			rec.credits.crate -= 1
			rec.owned[id] = true
			local it = Cosmetics.item(id)
			if it ~= nil and rec.equipped[it.kind] == nil then
				rec.equipped[it.kind] = id
			end
			got = id
			return rec
		end)
	end)
	if not ok then
		return false, "store unavailable: " .. tostring(err)
	end
	if stored ~= nil then
		remember(player, stored :: Record)
	end
	notify(player)
	if got == nil then
		return false, why
	end
	return true, got
end

--- Equip an owned item in its slot ("skin" / "flag"), or clear the slot (id false). Yields.
function Purchases.equip(player: any, slot: string, id: any): (boolean, string?)
	if slot ~= "skin" and slot ~= "flag" then
		return false, "bad slot"
	end
	if id ~= false then
		local it = Cosmetics.item(id)
		if it == nil or it.kind ~= slot then
			return false, "unknown item"
		end
	end
	-- (nothing to write: already worn, or not theirs)
	local known = records[player]
	if known ~= nil then
		if id ~= false and not known.owned[id] then
			Purchases.stats.skipped += 1
			return false, "not owned"
		end
		if known.equipped[slot] == (if id == false then nil else id) then
			Purchases.stats.skipped += 1
			return true, nil
		end
	end
	local done = false
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			done = false
			local rec = clean(old, player.UserId)
			stored = rec
			if id ~= false and not rec.owned[id] then
				return nil
			end
			rec.equipped[slot] = if id == false then nil else id
			done = true
			return rec
		end)
	end)
	if not ok then
		return false, "store unavailable: " .. tostring(err)
	end
	if stored ~= nil then
		remember(player, stored :: Record)
	end
	notify(player)
	return done, if done then nil else "not owned"
end

--- Pays `amount` Stars (a match's payout, Data/Stars). Yields. (ok, the new balance).
--- The Stars for finishing the tutorial (Data/Tutorial), once per player. True when they were paid now.
--- A payout `entry` ({ id, stars, tutorial? }): owed until stored, stored now if the store takes it.
--- Returns the record as stored, or nil when it is owed for now (tried again, kept when they leave).
local function pay(player: any, entry: any, what: string): Record?
	local uid = player.UserId
	Purchases.stats.payouts += 1
	local list = owed[uid] or {}
	table.insert(list, entry)
	owed[uid] = list
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(uid, function(old: any): any
			stored = clean(old, uid)
			return nil -- (update stores the owed payouts, this one with them)
		end)
	end)
	if ok and stored ~= nil then
		remember(player, stored :: Record)
		notify(player)
		return stored
	end
	for _, e in owed[uid] or {} do
		if not e.late then
			e.late = true
			Purchases.stats.owed_new += 1
		end
	end
	log(string.format("%d %s Stars for %d owed for now: %s", entry.stars, what, uid, tostring(err)))
	notify(player)
	retry_owed(player)
	return nil
end

function Purchases.tutorial_bonus(player: any, amount: number): boolean
	local add = math.floor(tonumber(amount) or 0)
	if add ~= add or add <= 0 then
		return false
	end
	local known = records[player]
	if known ~= nil and known.tutorial_paid then
		Purchases.stats.skipped += 1
		return false -- (paid before: nothing to write)
	end
	local id = new_id()
	local stored = pay(player, { id = id, stars = add, tutorial = true }, "tutorial")
	return stored ~= nil and table.find(stored.payouts, id) ~= nil
end

--- RoWorld General (Data/Subscription; 2026-10-27; server/General calls it while Roblox says the
--- player is subscribed): UTC day `day`'s crate credit, or, where crates aren't allowed (`crates`
--- false), Subscription.DAILY_STARS Stars, once a day; and the month's General skin `skin`, kept for
--- good (put on when no skin is worn). Returns what it gave now ({ crate?, stars?, skin? }; {} when
--- the day's were given already), or nil when the store failed (tried again later).
function Purchases.general_perks(player: any, day: number, skin: string?, crates: boolean): any
	local it = if skin ~= nil then Cosmetics.item(skin) else nil
	-- (this day's given already, and the month's skin owned: nothing to write; every server they join
	-- asks once)
	local known = records[player]
	if known ~= nil and known.general_day == day and (it == nil or not it.general or known.owned[it.id]) then
		Purchases.stats.skipped += 1
		return {}
	end
	local stored: Record? = nil
	local given: any = {}
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			local rec = clean(old, player.UserId)
			stored = rec
			given = {}
			local changed = false
			if rec.general_day ~= day then
				rec.general_day = day
				if crates then
					rec.credits.crate = math.min((rec.credits.crate or 0) + 1, Purchases.MAX_CREDITS)
					given.crate = true
				else
					rec.stars = math.min(rec.stars + Subscription.DAILY_STARS, Purchases.MAX_STARS)
					rec.stars_earned = math.min(rec.stars_earned + Subscription.DAILY_STARS, Purchases.MAX_STARS)
					given.stars = Subscription.DAILY_STARS
				end
				changed = true
			end
			if it ~= nil and it.general and not rec.owned[it.id] then
				rec.owned[it.id] = true
				if rec.equipped[it.kind] == nil then
					rec.equipped[it.kind] = it.id
				end
				given.skin = it.id
				changed = true
			end
			return if changed then rec else nil
		end)
	end)
	if not ok or stored == nil then
		log("could not give " .. tostring(player.UserId) .. " their General's day: " .. tostring(err))
		return nil
	end
	remember(player, stored :: Record)
	if next(given) ~= nil then
		notify(player)
	end
	return given
end

--- Rofront Staging's "Replay as new player": the tutorial's Stars can be earned again, the first
--- crate's price is on offer again, and so is the starter pack (as one who never paid, its clock not
--- started, and without the pack's three items, which a new player doesn't have: the only things
--- taken; Stars, cosmetics and other unlocks stay). `keep_owned` (a game admin on production,
--- 2026-10-27): nothing is taken, and one who paid is still one who paid.
function Purchases.reset_new_player(player: any, keep_owned: boolean?): boolean
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			local rec = clean(old, player.UserId)
			rec.tutorial_paid = nil
			rec.crates_bought = 0
			rec.starter = nil
			if not keep_owned then
				rec.paid = false
				for _, k in Starter.ITEMS do
					rec.unlocks[k] = nil
				end
			end
			stored = rec
			return rec
		end)
	end)
	if not ok or stored == nil then
		log("could not reset " .. tostring(player.UserId) .. ": " .. tostring(err))
		return false
	end
	remember(player, stored :: Record)
	notify(player)
	return true
end

--- A match's Stars: stored now, or owed until they are (shown either way). Yields. (ok, the balance).
function Purchases.add_stars(player: any, amount: number): (boolean, number)
	local add = math.floor(tonumber(amount) or 0)
	if add ~= add or add <= 0 then
		return false, Purchases.stars(player)
	end
	pay(player, { id = new_id(), stars = add }, "match")
	return true, Purchases.stars(player)
end

--- Unlock Arsenal item `key` with Stars: one write takes its price and unlocks it. Yields.
--- (ok) or (false, "unknown item" | "robux only" | "owned" | "not enough" | "store unavailable: ...").
function Purchases.buy_unlock(player: any, item_key: any): (boolean, string?)
	local it = Arsenal.item(item_key)
	if it == nil then
		return false, "unknown item"
	end
	if it.stars == nil then
		return false, "robux only"
	end
	local known = settled_record(player)
	if known ~= nil then
		-- (nothing to write: owned, or short even with the Stars owed to them, which the write would add)
		if known.unlocks[it.key] then
			Purchases.stats.skipped += 1
			return false, "owned"
		end
		if known.stars + owed_stars(player.UserId) < it.stars then
			Purchases.stats.skipped += 1
			return false, "not enough"
		end
	end
	local why = "store unavailable"
	local done = false
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			done = false
			local rec = clean(old, player.UserId)
			stored = rec
			if rec.unlocks[it.key] then
				why = "owned"
				return nil
			end
			if rec.stars < it.stars then
				why = "not enough"
				return nil
			end
			rec.stars -= it.stars
			unlock_on(rec, it, 0)
			done = true
			return rec
		end)
	end)
	if not ok then
		return false, "store unavailable: " .. tostring(err)
	end
	if stored ~= nil then
		remember(player, stored :: Record)
	end
	notify(player)
	if not done then
		return false, why
	end
	if deps.unlocked then
		pcall(deps.unlocked, player, it.key)
	end
	log(string.format("%d unlocked %s for %d Stars", player.UserId, it.key, it.stars))
	return true, nil
end

return Purchases
