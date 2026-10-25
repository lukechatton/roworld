--!strict
-- Robux developer products (Creator Dashboard → Monetization → Developer Products). `id` is the
-- product's id; 0 = not created yet (its offer stays hidden). Each purchase is a saved credit of kind
-- `grants` (default: the key), `count` of them (default 1) (server/Purchases.luau): bought credits are
-- never lost if the moment passes. A `grants` of "unlock:<key>" is not a credit: it unlocks that
-- Arsenal item for good (Data/Arsenal).
--
-- Product ids belong to one experience. `staging` is the same product in Rofront Staging (2026-10-04:
-- a separate experience where a build is tested before it goes to prod); in that experience it
-- replaces `id`. Create or reprice them with
-- tools/assets/make_arsenal_products.py.
local PRODUCTS: { [string]: any } = {
	--- Solo / public: take over the AI nation that eliminated you (2026-09-28).
	takeover = { id = 3715363250, robux = 25, staging = 3716610101 },
	--- A cosmetic crate (Data/Cosmetics; 2026-09-29: 49 Robux, the first one 15).
	crate = { id = 3715469100, robux = 49, staging = 3716610114 },
	--- The first crate a player buys (offered only before their first crate).
	crate_first = { id = 3715469104, robux = 15, grants = "crate", first_only = true, staging = 3716610118 },
	--- Three crates at once (2026-10-19: 100 Robux instead of 120,
	--- three crates being 3 x 40 at their price): `count` crate credits for one receipt.
	crate3 = { id = 3720068382, robux = 100, grants = "crate", count = 3, staging = 3720061533 },
	--- The Arsenal (Data/Arsenal; 2026-10-04), at Pixel Conquest's prices.
	unlock_mega = { id = 3716621701, robux = 39, grants = "unlock:mega", staging = 3716609998 },
	unlock_scatter = { id = 3716621706, robux = 67, grants = "unlock:scatter", staging = 3716610004 },
	unlock_reinforce = { id = 3716621710, robux = 149, grants = "unlock:reinforce", staging = 3716610015 },
	unlock_artillery = { id = 3716621715, robux = 99, grants = "unlock:artillery", staging = 3716610019 },
	unlock_airfield = { id = 3716621718, robux = 349, grants = "unlock:airfield", staging = 3716610030 },
	unlock_railgun = { id = 3716621726, robux = 999, grants = "unlock:railgun", staging = 3716610035 },
	unlock_stars2x = { id = 3716621730, robux = 59, grants = "unlock:stars2x", staging = 3716610048 },
	unlock_reload2x = { id = 3716621734, robux = 129, grants = "unlock:reload2x", staging = 3716610055 },
	--- The starter pack (Data/Starter; 2026-10-15: 39 Robux, limited time): Mega Nuke, Scattershot
	--- and 2x Stars, once, for a player who never paid. Its receipt is refused outside its offer.
	starter_pack = { id = 3718883874, robux = 39, grants = "starter", staging = 3718864635 },
}

--- The flag shop (Data/Shop; 2026-10-22): one product per flag, made by
--- tools/assets/make_shop_flags.py (the ids live in Assets/ShopFlags), each granting "shopflag:<key>".
--- `shop_flag` marks them: UI/Prices asks Roblox for these only when the shop shows them.
local Shop: any = if typeof(game) == "Instance"
	then require((script :: any).Parent.Shop)
	else (require :: any)("./Shop")
for _, f in Shop.flags() do
	PRODUCTS["shop_" .. f.key] = {
		id = f.product or 0,
		robux = Shop.price(f),
		grants = "shopflag:" .. f.key,
		staging = f.staging or 0,
		shop_flag = f.key,
	}
end

--- A set's bundle (Data/Shop.SETS `bundle`; 2026-10-24): all its flags in one product, granting
--- "shopset:<id>".
for sid, s in Shop.SETS do
	if s.bundle ~= nil then
		local prod, staging = Shop.bundle_ids(sid)
		PRODUCTS["shopset_" .. sid] = {
			id = prod,
			robux = s.bundle,
			grants = "shopset:" .. sid,
			staging = staging,
			shop_set = sid,
		}
	end
end

--- Rofront Staging (Data/Staging): there every product is its `staging` one.
local Staging: any = if typeof(game) == "Instance"
	then require((script :: any).Parent.Staging)
	else (require :: any)("./Staging")

if Staging.here() then
	for _, p in PRODUCTS do
		p.id = p.staging or 0
	end
end

return PRODUCTS
