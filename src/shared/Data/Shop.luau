--!strict
-- The flag shop (2026-10-22: a daily rotating shop of flags for sale, with a
-- Halloween set first; docs/flag-shop.md). Flags you choose and buy for Robux, each its own developer
-- product (Assets/ShopFlags: the art, the product ids). They are cosmetics like the crates' flags
-- (Data/Cosmetics: item "shop_<key>", kind "flag"), but never in a crate and never on a bot player.
--
--   the daily shop   DAILY flags from the pool (the flags of no set), new every day at 00:00 UTC. Every
--                    server and client works the day's out from the date alone (Shop.daily): the pool
--                    is shuffled once per cycle of floor(#pool / DAILY) days, each day takes the next
--                    DAILY of it, so a flag doesn't come back within a cycle; a cycle's first day never
--                    repeats the day before.
--   sets             a limited set (SETS: Halloween) is on sale whole between its `from` and `to`; with
--                    a `bundle` price, all of it is one product too (2026-10-24, from the analytics
--                    suggestions: the set's 6 flags as one bundle at a discount).
--
-- A receipt grants its flag whenever it comes (the prompt may close after the shop turned over).
local IS_ROBLOX = typeof(game) == "Instance"
local ShopFlags: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Assets.ShopFlags)
	else require("../Assets/ShopFlags")

local Shop = {}

Shop.DAY_S = 86400
--- Flags in the daily shop.
Shop.DAILY = 4
--- Robux by rarity (each flag's product is created at its rarity's price: make_shop_flags.py).
Shop.PRICES = { rare = 49, epic = 99, legendary = 149 }
--- The item id prefix (Data/Cosmetics).
Shop.ITEM_PREFIX = "shop_"

--- Limited sets: on sale whole from `from` to `to` (Unix seconds, UTC); `bundle`: the Robux of all of
--- it at once (its product: Assets/ShopFlags `sets`).
Shop.SETS = {
	-- 2026-10-22 .. 2026-11-03; all 6 for 299 (544 one by one)
	halloween = { name = "Halloween", from = 1792627200, to = 1793664000, bundle = 299 },
}

type Flag = { key: string, name: string, rarity: string, theme: string, set: string?, [string]: any }

local flags: { Flag } = {}
local by_key: { [string]: Flag } = {}
local pool: { string } = {}
for _, f in (ShopFlags.flags or {}) :: { any } do
	table.insert(flags, f)
	by_key[f.key] = f
	if f.set == nil then
		table.insert(pool, f.key)
	end
end
table.sort(pool)

function Shop.flags(): { Flag }
	return flags
end

function Shop.flag(key: any): Flag?
	return if type(key) == "string" then by_key[key] else nil
end

--- The daily pool's keys (sorted).
function Shop.pool(): { string }
	return pool
end

function Shop.price(f: any): number
	return Shop.PRICES[f and f.rarity or ""] or Shop.PRICES.rare
end

function Shop.item_id(key: string): string
	return Shop.ITEM_PREFIX .. key
end

--- The shop flag key of item id `id` (nil: not a shop flag's id).
function Shop.key_of(id: any): string?
	if type(id) ~= "string" or string.sub(id, 1, #Shop.ITEM_PREFIX) ~= Shop.ITEM_PREFIX then
		return nil
	end
	local key = string.sub(id, #Shop.ITEM_PREFIX + 1)
	return if by_key[key] ~= nil then key else nil
end

--- The UTC day number of Unix time `t`.
function Shop.day(t: number): number
	return math.floor(t / Shop.DAY_S)
end

--- Seconds from `t` until the shop turns over.
function Shop.next_in(t: number): number
	return (Shop.day(t) + 1) * Shop.DAY_S - t
end

-- xorshift32 (bit32: the same numbers in every Luau, so every server and client agrees)
local function rng(seed: number): () -> number
	local s = bit32.band(seed, 0xFFFFFFFF)
	if s == 0 then
		s = 0x9E3779B9
	end
	return function(): number
		s = bit32.bxor(s, bit32.lshift(s, 13))
		s = bit32.bxor(s, bit32.rshift(s, 17))
		s = bit32.bxor(s, bit32.lshift(s, 5))
		return s
	end
end

--- The pool shuffled for cycle `c` (before the first-day rule).
local function deck(list: { string }, c: number): { string }
	local d = table.clone(list)
	local next = rng(bit32.bxor((c * 2654435761) % 4294967296, 0x5BD1E995))
	for _ = 1, 3 do
		next() -- (mix the seed)
	end
	for i = #d, 2, -1 do
		local j = next() % i + 1
		d[i], d[j] = d[j], d[i]
	end
	return d
end

local function slice(d: { string }, k: number, n: number): { string }
	local out = {}
	for i = k * n + 1, k * n + n do
		table.insert(out, d[i])
	end
	return out
end

--- The daily shop's keys on UTC day `day` (`list`: the pool, by default Shop.pool()).
function Shop.daily(day: number, list: { string }?): { string }
	local p = list or pool
	local n = Shop.DAILY
	if #p <= n then
		return table.clone(p)
	end
	local days = math.floor(#p / n)
	local c, k = math.floor(day / days), day % days
	local d = deck(p, c)
	-- a cycle's days are its deck's slices; the cycle's first day is a slice with nothing from the day
	-- before (the last slice of the previous cycle's deck, which this rule never moves)
	if days >= n + 2 then
		local prev = slice(deck(p, c - 1), days - 1, n)
		local seen = {}
		for _, key in prev do
			seen[key] = true
		end
		local first = 0
		for s = 0, days - 2 do
			local clear = true
			for _, key in slice(d, s, n) do
				if seen[key] then
					clear = false
					break
				end
			end
			if clear then
				first = s
				break
			end
		end
		if first > 0 then
			-- (that slice goes first; the others keep their order, the last one stays last)
			local moved = slice(d, first, n)
			for _ = 1, n do
				table.remove(d, first * n + 1)
			end
			for i = n, 1, -1 do
				table.insert(d, 1, moved[i])
			end
		end
	end
	return slice(d, k, n)
end

--- The limited sets on sale at `t`: { { id, name, ends, keys } } (by `to`).
function Shop.sets(t: number): { any }
	local out = {}
	for id, s in Shop.SETS do
		if t >= s.from and t < s.to then
			local keys = {}
			for _, f in flags do
				if f.set == id then
					table.insert(keys, f.key)
				end
			end
			if #keys > 0 then
				table.insert(out, { id = id, name = s.name, ends = s.to, keys = keys })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.ends < b.ends
	end)
	return out
end

--- The keys of set `id` (rarest first, then by name).
function Shop.set_keys(id: string): { string }
	local keys = {}
	for _, f in flags do
		if f.set == id then
			table.insert(keys, f.key)
		end
	end
	local rank = { legendary = 1, epic = 2, rare = 3 }
	table.sort(keys, function(a, b)
		local fa, fb = by_key[a], by_key[b]
		local ra, rb = rank[fa.rarity] or 9, rank[fb.rarity] or 9
		if ra ~= rb then
			return ra < rb
		end
		return fa.name < fb.name
	end)
	return keys
end

--- Set `id`'s bundle product ids: (production, Rofront Staging); 0 = not made yet.
function Shop.bundle_ids(id: string): (number, number)
	local s = (ShopFlags.sets or {})[id]
	return if s then s.product or 0 else 0, if s then s.staging or 0 else 0
end

--- Set `id`'s flags bought one by one (Robux).
function Shop.set_total(id: string): number
	local n = 0
	for _, k in Shop.set_keys(id) do
		n += Shop.price(by_key[k])
	end
	return n
end

--- Is flag `key` on sale at `t` (today's daily shop or a running set)?
function Shop.on_sale(key: string, t: number): boolean
	for _, k in Shop.daily(Shop.day(t)) do
		if k == key then
			return true
		end
	end
	for _, s in Shop.sets(t) do
		if table.find(s.keys, key) then
			return true
		end
	end
	return false
end

return Shop
