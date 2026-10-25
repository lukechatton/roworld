--!strict
-- Robux purchases (developer products, shared/Data/Products). A purchase is a saved credit: Roblox's
-- ProcessReceipt adds it to the player's record in its own DataStore (only the server writes it —
-- the client's SETTING op can't touch it) and only then reports the purchase granted, so Roblox
-- retries until it is stored and a receipt is never granted twice (its PurchaseId is kept). The game
-- spends a credit when the moment comes (Purchases.use); one bought after the moment passed stays
-- for the next time.
--
--   Purchases.configure(deps)     { datastore = DataStore, notify = fn(player, credits), log? }
--   Purchases.process_receipt(info) -> "granted" | "not_processed"   (a product's `count` credits)
--   Purchases.load(player)        read the record (join; retried while Roblox refuses it); notify
--   Purchases.credits(player) -> { [kind]: number }
--   Purchases.use(player, kind) -> (ok, err?)   spend one (yields)
--   Purchases.release(player)     PlayerRemoving
--   Purchases.open_crate(player) -> (ok, item_id | err)   spend a crate credit, roll (never a duplicate)
--   Purchases.equip(player, slot, id | false) -> (ok, err?)   "skin" / "flag"; only owned items
--   Purchases.inventory(player) -> { owned = { id }, equipped = { skin?, flag? }, crates_bought,
--                                    stars, unlocks = { key } }
--   Purchases.add_stars(player, amount) -> (ok, balance)   a match's Stars (Data/Stars; yields)
--   Purchases.buy_unlock(player, key) -> (ok, err?)        unlock an Arsenal item with Stars (yields)
--   Purchases.has_unlock(player, key) / Purchases.unlock_mask(player)   what the player has unlocked
--   Purchases.starter_state(player) -> false | { state = "ready" } | { state = "active", left = s }
--   Purchases.starter_seen(player)   the starter pack is on their screen: its clock starts (once; yields)
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

local deps: { [string]: any } = {}
local cache: { [any]: { [string]: number } } = {}
--- the player's items (the record's owned / equipped / crates_bought), as last read or written
local inv: { [any]: any } = {}
--- player -> the load that is still trying to read their record (a token: a newer load, a write
--- that brought the record, or leaving ends it)
local loading: { [any]: any } = {}

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
	loading[player] = nil -- (the record is here: a load still retrying has nothing left to do)
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
		stars = if i ~= nil then i.stars else 0,
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
	local started = false
	local stored: Record? = nil
	local ok, err = pcall(function()
		deps.datastore:UpdateAsync(key(player.UserId), function(old: any): any
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

function Purchases.stars(player: any): number
	local i = inv[player]
	return if i ~= nil then i.stars else 0
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
		deps.datastore:UpdateAsync(key(user_id), function(old: any): any
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

--- Yields: LOAD_ATTEMPTS reads with LOAD_BACKOFF between them, then, with the session already going
--- on an empty record, more every LOAD_RETRY_S (deps.wait; without one, a single attempt).
function Purchases.load(player: any)
	local token = {}
	loading[player] = token
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
	local spent = false
	local left: { [string]: number }? = nil
	local ok, err = pcall(function()
		deps.datastore:UpdateAsync(key(player.UserId), function(old: any): any
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

function Purchases.release(player: any)
	loading[player] = nil
	cache[player] = nil
	inv[player] = nil
end

--- Open one crate: spend a crate credit and add an item the player doesn't own (Cosmetics.roll, the
--- published odds), in one write; the new item is equipped when its slot is empty. Yields.
--- (ok, item_id) or (false, "no crate" | "everything owned" | "store unavailable: ...").
function Purchases.open_crate(player: any): (boolean, string?)
	local rng = deps.rng or Random.new()
	local got: string? = nil
	local why = "no crate"
	local stored: Record? = nil
	local ok, err = pcall(function()
		deps.datastore:UpdateAsync(key(player.UserId), function(old: any): any
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
	local done = false
	local stored: Record? = nil
	local ok, err = pcall(function()
		deps.datastore:UpdateAsync(key(player.UserId), function(old: any): any
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
function Purchases.tutorial_bonus(player: any, amount: number): boolean
	local add = math.floor(tonumber(amount) or 0)
	if add ~= add or add <= 0 then
		return false
	end
	local stored: Record? = nil
	local paid = false
	local ok, err = pcall(function()
		deps.datastore:UpdateAsync(key(player.UserId), function(old: any): any
			local rec = clean(old, player.UserId)
			stored = rec
			if rec.tutorial_paid then
				paid = false
				return nil
			end
			paid = true
			rec.tutorial_paid = true
			rec.stars = math.min(rec.stars + add, Purchases.MAX_STARS)
			rec.stars_earned = math.min(rec.stars_earned + add, Purchases.MAX_STARS)
			return rec
		end)
	end)
	if not ok or stored == nil then
		log("could not pay the tutorial's Stars to " .. tostring(player.UserId) .. ": " .. tostring(err))
		return false
	end
	remember(player, stored :: Record)
	if paid then
		notify(player)
	end
	return paid
end

--- Rofront Staging's "Replay as new player": the tutorial's Stars can be earned again, the first
--- crate's price is on offer again, and so is the starter pack (as one who never paid, its clock not
--- started, and without the pack's three items, which a new player doesn't have: the only things
--- taken; Stars, cosmetics and other unlocks stay).
function Purchases.reset_new_player(player: any): boolean
	local stored: Record? = nil
	local ok, err = pcall(function()
		deps.datastore:UpdateAsync(key(player.UserId), function(old: any): any
			local rec = clean(old, player.UserId)
			rec.tutorial_paid = nil
			rec.crates_bought = 0
			rec.paid = false
			rec.starter = nil
			for _, k in Starter.ITEMS do
				rec.unlocks[k] = nil
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

function Purchases.add_stars(player: any, amount: number): (boolean, number)
	local add = math.floor(tonumber(amount) or 0)
	if add ~= add or add <= 0 then
		return false, Purchases.stars(player)
	end
	local stored: Record? = nil
	local ok, err = pcall(function()
		deps.datastore:UpdateAsync(key(player.UserId), function(old: any): any
			local rec = clean(old, player.UserId)
			rec.stars = math.min(rec.stars + add, Purchases.MAX_STARS)
			rec.stars_earned = math.min(rec.stars_earned + add, Purchases.MAX_STARS)
			stored = rec
			return rec
		end)
	end)
	if not ok or stored == nil then
		log("could not pay " .. tostring(add) .. " Stars to " .. tostring(player.UserId) .. ": " .. tostring(err))
		return false, Purchases.stars(player)
	end
	remember(player, stored :: Record)
	notify(player)
	return true, (stored :: Record).stars
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
	local why = "store unavailable"
	local done = false
	local stored: Record? = nil
	local ok, err = pcall(function()
		deps.datastore:UpdateAsync(key(player.UserId), function(old: any): any
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
