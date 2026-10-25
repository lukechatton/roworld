--!nocheck
-- The flag shop (Data/Shop, docs/flag-shop.md): the daily rotation every server and client works out
-- alike (no flag twice within a cycle, nor on the day after a cycle's last), the limited sets' windows,
-- the shop flags as cosmetics (never in a crate) and products, and a purchase: the flag owned and worn,
-- a retried receipt once, a second purchase of an owned flag paid back in Stars.
require("./prelude")
local Shop = require("../src/shared/Data/Shop")
local Cosmetics = require("../src/shared/Data/Cosmetics")
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

local pool = Shop.pool()
expect(#Shop.flags() >= 24 and #pool >= 20, ("catalog: %d flags, %d in the daily pool"):format(#Shop.flags(), #pool))
for _, key in pool do
	if Shop.flag(key).set ~= nil then
		expect(false, "the pool holds no set flag: " .. key)
	end
end

-- the rotation
local days = math.floor(#pool / Shop.DAILY)
local d0 = 20748 -- 2026-10-22
local same = true
for d = d0, d0 + 30 do
	local a, b = Shop.daily(d), Shop.daily(d)
	if table.concat(a, ",") ~= table.concat(b, ",") or #a ~= Shop.DAILY then
		same = false
	end
end
expect(same, "a day's shop is the same every time it is worked out, DAILY flags")
local distinct, from_pool = true, true
for d = d0, d0 + 400 do
	local seen = {}
	for _, k in Shop.daily(d) do
		if seen[k] then
			distinct = false
		end
		seen[k] = true
		if not table.find(pool, k) then
			from_pool = false
		end
	end
end
expect(distinct and from_pool, "a day's flags are different ones, all from the pool")
local cycle_clean, boundary_clean = true, true
local start = math.floor(d0 / days) * days
for c = 0, 199 do
	local seen = {}
	for k = 0, days - 1 do
		for _, key in Shop.daily(start + c * days + k) do
			if seen[key] then
				cycle_clean = false
			end
			seen[key] = true
		end
	end
	local last = {}
	for _, key in Shop.daily(start + c * days + days - 1) do
		last[key] = true
	end
	for _, key in Shop.daily(start + (c + 1) * days) do
		if last[key] then
			boundary_clean = false
		end
	end
end
expect(cycle_clean, ("no flag twice within a cycle (%d days), 200 cycles"):format(days))
expect(boundary_clean, "a cycle's first day shares nothing with the day before, 200 cycles")
local shown = {}
for d = d0, d0 + 90 do
	for _, k in Shop.daily(d) do
		shown[k] = true
	end
end
local all_shown = true
for _, k in pool do
	if not shown[k] then
		all_shown = false
	end
end
expect(all_shown, "every pool flag comes up within 90 days")
local differ = 0
for d = d0, d0 + 59 do
	if table.concat(Shop.daily(d), ",") ~= table.concat(Shop.daily(d + 1), ",") then
		differ += 1
	end
end
expect(differ == 60, "the shop changes every day")
expect(Shop.next_in(d0 * 86400 + 3600) == 82800, "the clock: 23 h to the next shop at 01:00 UTC")

-- the Halloween set
local hs = Shop.sets(1792627200 + 3 * 86400)
expect(#hs == 1 and hs[1].id == "halloween" and #hs[1].keys == 6, "Halloween is on sale on 2026-10-25, 6 flags")
expect(#Shop.sets(1793664000) == 0 and #Shop.sets(1792627200 - 1) == 0, "... and not before 10-22 nor from 11-03")
local t = 1792627200 + 86400 + 50
expect(Shop.on_sale("pumpkin_king", t), "on sale: a set flag while the set runs")
expect(Shop.on_sale(Shop.daily(Shop.day(t))[1], t), "on sale: today's daily flag")
local off = nil
for _, k in pool do
	if not table.find(Shop.daily(Shop.day(t)), k) then
		off = k
		break
	end
end
expect(off ~= nil and not Shop.on_sale(off, t), "not on sale: a pool flag not in today's shop")

-- cosmetics and products
local it = Cosmetics.item("shop_pumpkin_king")
expect(
	it ~= nil and it.kind == "flag" and it.shop and it.rarity == "legendary",
	"the shop flag is a Legendary flag item"
)
expect(Cosmetics.flag_image(it) ~= "" and it.w > 0, "... with its sheet and rect")
local img = Cosmetics.flag_big(it)
expect(type(img) == "string" and img ~= "", "... and a big one for the shop's cards")
local in_crate = false
for _, c in Cosmetics.all() do
	if c.shop then
		in_crate = true
	end
end
expect(not in_crate, "no shop flag in the crate catalog (nor on a bot player)")
expect(
	Cosmetics.crate_owned({ shop_pumpkin_king = true, flag_us = true }) == 1,
	"the Locker's N of M counts crate items only"
)
expect(Shop.key_of("shop_kraken") == "kraken" and Shop.key_of("flag_us") == nil, "key_of: shop ids only")
local p = Products.shop_pumpkin_king
expect(
	p ~= nil and p.grants == "shopflag:pumpkin_king" and p.robux == Shop.PRICES.legendary,
	"its product: 149 Robux, grants the flag"
)
expect(Products.shop_cat ~= nil and Products.shop_cat.robux == Shop.PRICES.rare, "a Rare flag's product is 49 Robux")

-- a purchase
local rows = {}
local store = {}
function store:UpdateAsync(k, fn)
	local v = fn(rows[k])
	if v ~= nil then
		rows[k] = v
	end
	return v
end
function store:GetAsync(k)
	return rows[k]
end
local P = { UserId = 7, Name = "Flagger" }
local bought = {}
Purchases.reset()
Purchases.configure({
	datastore = store,
	players = {
		GetPlayerByUserId = function(_, id)
			return if id == 7 then P else nil
		end,
	},
	bought = function(_p, kind)
		table.insert(bought, kind)
	end,
})
Purchases.load(P)
Products.shop_kraken.id = 5550001
local r = Purchases.process_receipt({ PlayerId = 7, ProductId = 5550001, PurchaseId = "k1" })
local inv = Purchases.inventory(P)
expect(r == "granted" and table.find(inv.owned, "shop_kraken") ~= nil, "a shop flag's receipt: the flag is theirs")
expect(
	inv.equipped.flag == "shop_kraken" and bought[1] == "shopflag:kraken",
	"... worn at once; the server hears of it"
)
local stars = inv.stars
expect(
	Purchases.process_receipt({ PlayerId = 7, ProductId = 5550001, PurchaseId = "k1" }) == "granted"
		and Purchases.inventory(P).stars == stars,
	"the same receipt again (a retry): granted, nothing more"
)
expect(
	Purchases.process_receipt({ PlayerId = 7, ProductId = 5550001, PurchaseId = "k2" }) == "granted"
		and Purchases.inventory(P).stars == stars + Products.shop_kraken.robux * Purchases.DUPLICATE_STARS_PER_ROBUX,
	"a second purchase of an owned flag pays Stars for its price"
)
expect(Purchases.equip(P, "flag", "flag_us") == false, "equip: a flag they don't own is refused")
expect(Purchases.equip(P, "flag", false) and Purchases.equip(P, "flag", "shop_kraken"), "equip: off, then on again")

-- the Halloween bundle (2026-10-24): every flag of the set, the rarest new one worn, owned ones pay
-- back their share in Stars
expect(Shop.SETS.halloween.bundle == 299 and Shop.set_total("halloween") == 544, "the pack: 299 Robux for 544 of flags")
local hk = Shop.set_keys("halloween")
expect(#hk == 6 and hk[1] == "pumpkin_king", "its flags, rarest first")
expect(
	Products.shopset_halloween ~= nil and Products.shopset_halloween.grants == "shopset:halloween",
	"its product grants the set"
)
local Q = { UserId = 8, Name = "Packer" }
rows.u8 = { owned = { shop_phantom = true }, equipped = { flag = "flag_us" }, receipts = {} }
Purchases.configure({
	players = {
		GetPlayerByUserId = function(_, id)
			return if id == 8 then Q elseif id == 7 then P else nil
		end,
	},
})
Purchases.load(Q)
Products.shopset_halloween.id = 5550002
local before = Purchases.inventory(Q).stars
expect(
	Purchases.process_receipt({ PlayerId = 8, ProductId = 5550002, PurchaseId = "h1" }) == "granted",
	"the pack's receipt is granted"
)
local qi = Purchases.inventory(Q)
local all = true
for _, k in hk do
	if not table.find(qi.owned, "shop_" .. k) then
		all = false
	end
end
expect(all, "... all 6 Halloween flags are theirs")
expect(qi.equipped.flag == "shop_pumpkin_king", "... wearing the Pumpkin King (the rarest new one)")
local share = math.floor(299 * 49 / 544 * Purchases.DUPLICATE_STARS_PER_ROBUX)
expect(qi.stars == before + share, ("... Phantom, owned before, paid back its share: %d Stars"):format(share))

-- the FEATURED card: 2 x 2 cells top-left, the rest around it
local ShopLayout = require("../src/client/UI/ShopLayout")
local cells, rows_used = ShopLayout.place(6, true, 4)
expect(
	rows_used == 3 and cells[1][1] == 0 and cells[2][1] == 2 and cells[2][2] == 0 and cells[6][2] == 2,
	"6 cards with a hero in 4 columns: 3 rows"
)
local cells4, r4 = ShopLayout.place(4, true, 4)
expect(r4 == 2 and cells4[4][1] == 2 and cells4[4][2] == 1, "4 with a hero: 2 rows, the others to its right")
local _, r0 = ShopLayout.place(4, false, 4)
expect(r0 == 1, "4 without a hero: one row")
local ordered, hero = ShopLayout.order({ "cat", "pumpkin_king", "bat_moon" })
expect(hero and ordered[1] == "pumpkin_king", "a section with a Legendary features it")
local _, nohero = ShopLayout.order({ "cat", "bat_moon" })
expect(not nohero, "... and one without has no featured card")

if fails > 0 then
	error(("shop: %d failed"):format(fails))
end
print("shop ok")
