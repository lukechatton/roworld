--!nocheck
-- Robux purchases (server/Purchases.luau): a receipt becomes a stored credit before it is granted,
-- a retried receipt is granted again without a second credit, a store outage is "not processed"
-- (Roblox retries), credits are spent one at a time.
require("./prelude")
local Products = require("../src/shared/Data/Products")
local Purchases = require("../src/server/Purchases")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- a DataStore with UpdateAsync / GetAsync semantics (nil from the transform = no write)
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

local P = { UserId = 42, Name = "Buyer" }
local notified = {}
local bought = {}
Purchases.configure({
	datastore = store,
	players = {
		GetPlayerByUserId = function(_, id)
			return if id == 42 then P else nil
		end,
	},
	notify = function(p, credits)
		table.insert(notified, credits.takeover or 0)
	end,
	bought = function(p, kind)
		table.insert(bought, kind)
	end,
})

Products.takeover.id = 777
Purchases.load(P)
expect(#notified == 1 and notified[1] == 0, "load: no credits, the client told")
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 999, PurchaseId = "r0" }) == "not_processed",
	"an unknown product is not processed"
)
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "r1" }) == "granted",
	"a takeover receipt is granted"
)
expect(
	Purchases.credits(P).takeover == 1 and notified[#notified] == 1 and bought[1] == "takeover",
	"one credit, stored and told"
)
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "r1" }) == "granted",
	"the same receipt again (a retry) is granted"
)
expect(Purchases.credits(P).takeover == 1 and rows.u42.credits.takeover == 1, "... without a second credit")
down = true
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "r2" }) == "not_processed",
	"store down: not processed (Roblox retries)"
)
down = false
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "r2" }) == "granted"
		and Purchases.credits(P).takeover == 2,
	"the retry after the outage lands: 2 credits"
)
expect(
	Purchases.process_receipt({ PlayerId = 7, ProductId = 777, PurchaseId = "r3" }) == "granted"
		and rows.u7.credits.takeover == 1,
	"a buyer not on this server is still credited"
)
local ok1 = Purchases.use(P, "takeover")
local ok2 = Purchases.use(P, "takeover")
local ok3, why = Purchases.use(P, "takeover")
expect(ok1 and ok2 and not ok3 and why == "no credit", "two uses, the third refused (" .. tostring(why) .. ")")
expect(rows.u42.credits.takeover == 0 and notified[#notified] == 0, "stored 0, the client told")
down = true
local ok4, why4 = Purchases.use(P, "takeover")
down = false
expect(not ok4 and string.find(why4, "store", 1, true) ~= nil, "store down: nothing spent (" .. tostring(why4) .. ")")
expect(not (Purchases.use(P, "nope")), "an unknown kind can't be spent")
for i = 1, Purchases.RECEIPTS_KEPT + 20 do
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "bulk" .. i })
end
expect(#rows.u42.receipts == Purchases.RECEIPTS_KEPT, "receipts kept are bounded (" .. #rows.u42.receipts .. ")")
Products.takeover.id = 0
expect(Purchases.kind_of(777) == nil, "a product not created yet (id 0) matches nothing")

-- crates: bought (the first at its own price) = crate credits; opening one spends it and adds an item
-- the player doesn't own, equipped when its slot is empty; nothing is spent without an item to give
do
	local Cosmetics = require("../src/shared/Data/Cosmetics")
	local B = { UserId = 99, Name = "Crater" }
	local inv_seen = nil
	Purchases.configure({
		players = {
			GetPlayerByUserId = function(_, id)
				return if id == 42 then P elseif id == 99 then B else nil
			end,
		},
		inventory = function(_p, i)
			inv_seen = i
		end,
		rng = {
			NextNumber = function(_)
				return math.random()
			end,
		},
	})
	Purchases.load(B)
	expect(
		Purchases.process_receipt({ PlayerId = 99, ProductId = Products.crate_first.id, PurchaseId = "c1" })
			== "granted",
		"the first crate (15) is a crate credit"
	)
	expect(
		Purchases.process_receipt({ PlayerId = 99, ProductId = Products.crate.id, PurchaseId = "c2" }) == "granted",
		"a crate (49) too"
	)
	expect(rows.u99.credits.crate == 2 and rows.u99.crates_bought == 2, "2 crate credits, 2 bought")
	local ok1, a = Purchases.open_crate(B)
	local ok2, b = Purchases.open_crate(B)
	local ok3, why = Purchases.open_crate(B)
	expect(
		ok1 and ok2 and a ~= b and Cosmetics.item(a) ~= nil and Cosmetics.item(b) ~= nil,
		"two crates: two different items (" .. tostring(a) .. ", " .. tostring(b) .. ")"
	)
	expect(not ok3 and why == "no crate" and rows.u99.credits.crate == 0, "no credit left: nothing opens")
	expect(rows.u99.owned[a] and rows.u99.owned[b], "both saved as owned")
	local ia, ib = Cosmetics.item(a), Cosmetics.item(b)
	expect(rows.u99.equipped[ia.kind] == a, "the first " .. ia.kind .. " was equipped (its slot was empty)")
	expect(inv_seen ~= nil and #inv_seen.owned == 2, "the client got the inventory")
	-- equip
	local okx, whyx = Purchases.equip(B, "skin", "gilded")
	expect((not okx and whyx == "not owned") or rows.u99.owned.gilded, "an item not owned can't be equipped")
	local owned_flag = if ia.kind == "flag" then a elseif ib.kind == "flag" then b else nil
	if owned_flag then
		expect(Purchases.equip(B, "flag", false) and rows.u99.equipped.flag == nil, "clear the flag slot")
		expect(Purchases.equip(B, "flag", owned_flag) and rows.u99.equipped.flag == owned_flag, "equip an owned flag")
	end
	expect(not (Purchases.equip(B, "flag", "stripes")), "a skin can't go in the flag slot")
	-- everything owned: a crate credit is kept
	local all = {}
	for _, it in Cosmetics.all() do
		all[it.id] = true
	end
	rows.u99.owned = all
	rows.u99.credits.crate = 1
	local okall, whyall = Purchases.open_crate(B)
	expect(
		not okall and whyall == "everything owned" and rows.u99.credits.crate == 1,
		"everything owned: the credit is kept"
	)
	-- store down: nothing changes
	rows.u99.owned = {}
	down = true
	local okd, whyd = Purchases.open_crate(B)
	down = false
	expect(
		not okd and string.find(whyd, "store", 1, true) ~= nil and rows.u99.credits.crate == 1,
		"store down: nothing spent"
	)
	-- junk in a stored record is dropped
	rows.u99.owned = { ["not_an_item"] = true, stripes = true }
	rows.u99.equipped = { skin = "gilded", flag = "flag_zz" }
	Purchases.load(B)
	local inv = Purchases.inventory(B)
	expect(
		#inv.owned == 1 and inv.owned[1] == "stripes" and inv.equipped.skin == nil,
		"unknown / unowned ids are dropped on load"
	)
end

-- a record Roblox refuses to give at first (DataStore throttling): the load tries again
do
	local real_get = store.GetAsync
	local refuse = 0
	store.GetAsync = function(self, k)
		if refuse > 0 then
			refuse -= 1
			error("DataStoreService: TooManyRequests: Too many requests, try again later. API: GetAsync")
		end
		return real_get(self, k)
	end
	rows.u77 = { unlocks = { mega = true }, stars = 1234, credits = { takeover = 2 } }
	local C = { UserId = 77, Name = "Throttled" }
	local waits, told, late = {}, {}, 0
	Purchases.configure({
		wait = function(s)
			table.insert(waits, s)
		end,
		notify = function(p, credits)
			if p == C then
				table.insert(told, credits.takeover or 0)
			end
		end,
		unlocked = function(p, _key)
			if p == C then
				late += 1
			end
		end,
	})
	-- refused three times, given on the fourth: nothing is missing, nobody is told of an empty record
	refuse = 3
	Purchases.load(C)
	expect(
		Purchases.has_unlock(C, "mega") and Purchases.stars(C) == 1234,
		"throttled 3 times: the record is read on the 4th try"
	)
	expect(#waits == 3 and waits[1] == 1 and waits[2] == 3 and waits[3] == 6, "with the waits of LOAD_BACKOFF between")
	expect(#told == 1 and told[1] == 2 and late == 0, "the client is told once, of the real record")
	-- refused through every first attempt: the session starts empty, and the read goes on
	Purchases.release(C)
	table.clear(waits)
	table.clear(told)
	refuse = Purchases.LOAD_ATTEMPTS + 2
	Purchases.load(C)
	expect(
		Purchases.has_unlock(C, "mega") and Purchases.unlock_mask(C) ~= 0,
		"refused 7 times: read on the 8th, in the background"
	)
	expect(#told == 2 and told[1] == 0 and told[2] == 2, "the client is told of an empty record, then of the real one")
	expect(late == 1, "and the match they are in learns their unlocks")
	expect(waits[#waits] == Purchases.LOAD_RETRY_S, "background tries are LOAD_RETRY_S apart")
	-- they leave while it is still trying: it stops
	Purchases.release(C)
	table.clear(told)
	refuse = 1000
	local gets = 0
	Purchases.configure({
		wait = function(_s)
			gets += 1
			if gets == 2 then
				Purchases.release(C)
			end
		end,
	})
	Purchases.load(C)
	expect(
		gets == 2 and refuse > 900 and not Purchases.has_unlock(C, "mega"),
		"a player who left is not read for any more"
	)
	-- never given: it gives up after LOAD_ATTEMPTS + LOAD_RETRIES tries
	local n = 0
	Purchases.configure({
		wait = function(_s)
			n += 1
		end,
	})
	Purchases.load(C)
	expect(
		n == Purchases.LOAD_ATTEMPTS + Purchases.LOAD_RETRIES - 1,
		"refused for good: it gives up after every try is spent"
	)
	-- a write that goes through meanwhile brings the record: the load has nothing left to do
	Purchases.release(C)
	local wrote = false
	Purchases.configure({
		wait = function(_s)
			if not wrote then
				wrote = true
				store.GetAsync = real_get
				Purchases.add_stars(C, 10)
				store.GetAsync = function()
					error("still throttled")
				end
			end
		end,
	})
	Purchases.load(C)
	expect(
		wrote and Purchases.stars(C) == 1244 and Purchases.has_unlock(C, "mega"),
		"a write that succeeds meanwhile brings the record"
	)
	store.GetAsync = real_get
	Purchases.configure({ wait = false })
end

-- the starter pack (Data/Starter): offered once to a player who never paid, a real 48-hour clock from
-- the first look, its receipt refused outside the offer
do
	local Starter = require("../src/shared/Data/Starter")
	local t = 1000000
	Purchases.configure({ now = function()
		return t
	end, wait = false })
	Products.starter_pack.id = 888
	Products.crate.id = 701
	local S = { UserId = 77, Name = "Starter" }
	local granted_to = {}
	Purchases.configure({
		players = {
			GetPlayerByUserId = function(_, id)
				return if id == 77 then S elseif id == 42 then P else nil
			end,
		},
		bought = function(p, kind)
			table.insert(granted_to, kind)
		end,
	})
	rows.u77 = nil
	Purchases.release(S)
	Purchases.load(S)
	expect(Purchases.starter_state(S) == false, "starter: a player who never played isn't offered it")
	Purchases.add_stars(S, 100)
	local st = Purchases.starter_state(S)
	expect(type(st) == "table" and st.state == "ready", "starter: after a match it is ready to show")
	expect(Purchases.inventory(S).starter.state == "ready", "starter: the inventory carries it")
	expect(
		Purchases.process_receipt({ PlayerId = 77, ProductId = 888, PurchaseId = "s0" }) == "not_processed",
		"starter: a receipt before the offer was shown is refused"
	)
	expect(rows.u77.starter == nil and not Purchases.has_unlock(S, "mega"), "... and nothing is stored")
	expect(Purchases.starter_seen(S) == true, "starter: shown, its clock starts")
	st = Purchases.starter_state(S)
	expect(st.state == "active" and st.left == Starter.DURATION_S, "starter: active, 48 hours left")
	t += 3600
	expect(Purchases.starter_seen(S) == false, "starter: shown again, the clock doesn't restart")
	expect(Purchases.starter_state(S).left == Starter.DURATION_S - 3600, "... an hour gone")
	-- Mega Nuke already unlocked with Stars: the pack pays its Stars instead
	rows.u77.unlocks = { mega = true }
	local before = rows.u77.stars
	expect(
		Purchases.process_receipt({ PlayerId = 77, ProductId = 888, PurchaseId = "s1" }) == "granted",
		"starter: bought while the offer runs"
	)
	expect(
		Purchases.has_unlock(S, "scatter") and Purchases.has_unlock(S, "stars2x") and Purchases.has_unlock(S, "mega"),
		"... Mega Nuke, Scattershot and 2x Stars"
	)
	expect(
		rows.u77.stars == before + 39 * Purchases.DUPLICATE_STARS_PER_ROBUX + 0,
		"... the Mega Nuke already had pays its Stars (39 Robux' worth)"
	)
	expect(rows.u77.starter.used == true and rows.u77.paid == true, "... used, and the player has paid")
	expect(granted_to[#granted_to] == "starter", "... the server hears it was bought")
	expect(Purchases.starter_state(S) == false, "starter: gone once bought")
	expect(
		Purchases.process_receipt({ PlayerId = 77, ProductId = 888, PurchaseId = "s1" }) == "granted",
		"starter: the same receipt again (a retry) is granted"
	)
	expect(
		Purchases.process_receipt({ PlayerId = 77, ProductId = 888, PurchaseId = "s2" }) == "not_processed",
		"starter: a second purchase is refused"
	)
	-- staging's "Replay as new player": offered again from the start, the pack's items taken back
	rows.u77.unlocks.railgun = true
	Purchases.reset_new_player(S)
	expect(
		not Purchases.has_unlock(S, "mega") and Purchases.has_unlock(S, "railgun"),
		"starter: replay as new player takes back only the pack's items"
	)
	expect(rows.u77.paid == false and rows.u77.starter == nil, "starter: replay as new player clears it")
	expect(Purchases.starter_state(S).state == "ready", "... ready again (the receipts are kept)")
	-- the clock runs out: the grace for a prompt opened in time, then refused; never offered again
	Purchases.starter_seen(S)
	t += Starter.DURATION_S + 60
	expect(Purchases.starter_state(S) == false, "starter: ended after 48 hours")
	expect(Purchases.starter_seen(S) == false, "... and seen again it doesn't restart")
	expect(Purchases.starter_state(S) == false, "... still gone")
	t += Starter.GRACE_S
	expect(
		Purchases.process_receipt({ PlayerId = 77, ProductId = 888, PurchaseId = "s3" }) == "not_processed",
		"starter: a purchase after the grace is refused"
	)
	Purchases.reset_new_player(S)
	Purchases.starter_seen(S)
	t += Starter.DURATION_S + Starter.GRACE_S - 5
	expect(
		Purchases.process_receipt({ PlayerId = 77, ProductId = 888, PurchaseId = "s4" }) == "granted",
		"starter: a prompt paid within the grace still lands"
	)
	-- a player who paid for something else first isn't offered it
	Purchases.reset_new_player(S)
	expect(
		Purchases.process_receipt({ PlayerId = 77, ProductId = 701, PurchaseId = "c1" }) == "granted",
		"a crate bought"
	)
	expect(Purchases.starter_state(S) == false, "starter: not for a player who has paid")
	-- a record from before `paid` existed: its receipts say it paid
	rows.u78 = { receipts = { "old" }, stars_earned = 50 }
	local O = { UserId = 78 }
	Purchases.load(O)
	expect(Purchases.starter_state(O) == false, "starter: an old record with receipts counts as paid")
	-- everything already unlocked: no offer
	rows.u79 = { stars_earned = 50, unlocks = { mega = true, scatter = true, stars2x = true } }
	local A = { UserId = 79 }
	Purchases.load(A)
	expect(Purchases.starter_state(A) == false, "starter: not offered when all of it is unlocked")
	-- no product here (and not Studio): nothing offered
	Products.starter_pack.id = 0
	rows.u80 = { stars_earned = 50 }
	local N = { UserId = 80 }
	Purchases.load(N)
	expect(Purchases.starter_state(N) == false, "starter: hidden while its product doesn't exist")
	Purchases.configure({ studio = true })
	expect(Purchases.starter_state(N).state == "ready", "... except in Studio")
	Purchases.configure({ studio = false, now = false })
end

-- the offer opens by itself at most every Starter.AUTO_GAP_S (6 h); the first sight always
do
	local Starter = require("../src/shared/Data/Starter")
	local now = 2000000000
	local gap = Starter.AUTO_GAP_S
	expect(gap == 6 * 3600, "starter auto: every 6 hours")
	expect(Starter.auto_due("ready", now - 10, now), "starter auto: never shown (its clock not started) always opens")
	expect(Starter.auto_due("active", nil, now) and Starter.auto_due("active", 0, now), "starter auto: running, never opened by itself: opens")
	expect(not Starter.auto_due("active", now - 60, now), "starter auto: a minute after the last: not again")
	expect(not Starter.auto_due("active", now - gap + 1, now), "starter auto: just under 6 hours: not yet")
	expect(Starter.auto_due("active", now - gap, now), "starter auto: 6 hours on: again")
	expect(Starter.auto_due("active", now + 3600, now), "starter auto: a last time in the future (clock went back) counts as never")
	expect(not Starter.auto_due(nil, 0, now) and not Starter.auto_due("used", 0, now), "starter auto: no offer: never")
end

-- Exclusive cosmetics (Cosmetics.exclusive_skins; 2026-10-18, Tie Dye for ilyannna): its owner owns
-- it whenever their record is read and wears it the first time; nobody else's record can hold it
do
	local F = { UserId = 58387889, Name = "ilyannna" }
	local X = { UserId = 81, Name = "Other" }
	local seen = {}
	Purchases.configure({
		players = {
			GetPlayerByUserId = function(_, id)
				return if id == F.UserId then F elseif id == X.UserId then X else nil
			end,
		},
		inventory = function(p, i)
			seen[p] = i
		end,
	})
	local fk = "u" .. F.UserId
	rows[fk] = { owned = { stripes = true }, equipped = { skin = "stripes" } }
	Purchases.load(F)
	local i = seen[F]
	expect(
		i ~= nil and table.find(i.owned, "tie_dye") ~= nil and i.equipped.skin == "tie_dye",
		"ilyannna's first join: tie_dye owned and worn (over the skin they had on)"
	)
	expect(Purchases.equipped(F) ~= nil and Purchases.equipped(F).skin == "tie_dye", "a match shows it on their land")
	expect(table.find(i.owned, "stripes") ~= nil, "what they owned before stays")
	expect(
		Purchases.equip(F, "skin", "stripes") and rows[fk].gifts.tie_dye == true and rows[fk].owned.tie_dye == true,
		"they change skin: the gift is saved with it"
	)
	Purchases.release(F)
	Purchases.load(F)
	expect(
		seen[F].equipped.skin == "stripes" and table.find(seen[F].owned, "tie_dye") ~= nil,
		"the next join keeps their choice and still owns tie_dye"
	)
	expect(Purchases.equip(F, "skin", "tie_dye") and rows[fk].equipped.skin == "tie_dye", "they can put it back on")
	rows.u81 = { owned = { tie_dye = true, stripes = true }, equipped = { skin = "tie_dye" } }
	Purchases.load(X)
	expect(
		table.find(seen[X].owned, "tie_dye") == nil and seen[X].equipped.skin == nil,
		"someone else's stored tie_dye is dropped"
	)
	local okx, whyx = Purchases.equip(X, "skin", "tie_dye")
	expect(not okx and whyx == "not owned", "and they can't equip it")
	expect(Purchases.equip(X, "skin", "stripes") and rows.u81.owned.tie_dye == nil, "their next save drops it")
	rows[fk] = nil
	Purchases.release(F)
	Purchases.load(F)
	expect(seen[F].equipped.skin == "tie_dye", "no record at all yet: owned and worn too")
end

-- the 3-crate pack (Data/Products crate3): one receipt, three crate credits, three crates bought;
-- a retried receipt adds none
do
	local K = { UserId = 64, Name = "Packer" }
	local told = {}
	Purchases.configure({
		players = {
			GetPlayerByUserId = function(_, id)
				return if id == 64 then K else nil
			end,
		},
		bought = function(_p, kind, n)
			table.insert(told, { kind, n })
		end,
	})
	Products.crate3.id = 703
	local kind, n = Purchases.kind_of(703)
	expect(kind == "crate" and n == 3, "the pack grants 3 crates")
	Purchases.load(K)
	expect(
		Purchases.process_receipt({ PlayerId = 64, ProductId = 703, PurchaseId = "p1" }) == "granted",
		"a pack receipt is granted"
	)
	expect(rows.u64.credits.crate == 3 and rows.u64.crates_bought == 3, "3 crate credits, 3 bought")
	expect(#told == 1 and told[1][1] == "crate" and told[1][2] == 3, "bought: told it was 3 crates")
	Purchases.process_receipt({ PlayerId = 64, ProductId = 703, PurchaseId = "p1" })
	expect(rows.u64.credits.crate == 3, "the same receipt again: no more crates")
	expect(select(2, Purchases.kind_of(Products.crate.id)) == 1, "a single crate is still 1")
	local opened = {}
	for _ = 1, 3 do
		local ok, id = Purchases.open_crate(K)
		if ok then
			opened[id] = true
		end
	end
	local distinct = 0
	for _ in opened do
		distinct += 1
	end
	expect(distinct == 3 and rows.u64.credits.crate == 0, "three crates open to three different items")
	Products.crate3.id = 0
	-- and the 10-crate pack (2026-10-27): ten credits for one receipt
	local kind10, n10 = Purchases.kind_of(Products.crate10.id)
	expect(kind10 == "crate" and n10 == 10, "the 10-pack grants 10 crates")
	expect(
		Purchases.process_receipt({ PlayerId = 64, ProductId = Products.crate10.id, PurchaseId = "p10" }) == "granted",
		"a 10-pack receipt is granted"
	)
	expect(rows.u64.credits.crate == 10 and rows.u64.crates_bought == 13, "10 crate credits, 13 bought in all")
end

if fails > 0 then
	error(fails .. " failures")
end
print("purchases: all passed")
