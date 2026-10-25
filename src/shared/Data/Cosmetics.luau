--!strict
-- Cosmetics you unlock from crates (2026-09-29: cosmetic loot boxes of territory skins and flags to
-- unlock; 49 Robux a crate, the first 15; never a duplicate; paid only; one crate for both).
--
--   skins   a territory pattern: a 1-bit mask tiled over your land (primary vs
--           secondary tiles; mask pixels are 2^scale tiles wide). '#' = the secondary colour: your
--           own colour lightened (tone > 0) or darkened (tone < 0), or a fixed `accent` colour
--           (legendary skins). Original designs.
--   flags   country flags (Assets/Flags, CC BY-SA 4.0), shown by your
--           name on the map and the leaderboard. Every flag is Common.
--   exclusive skins (exclusive_skins) are made for particular players: several colours, never in a
--           crate (Cosmetics.all() is the crate catalog; Cosmetics.exclusives() these).
--   shop flags (Data/Shop: "shop_<key>") are bought one by one in the flag shop: Rare, Epic or
--           Legendary, never in a crate nor on a bot player, not in the Locker's "N of M"
--           (Cosmetics.shop_items()).
--
-- A crate rolls a rarity by RARITIES odds, then an item of that rarity the player doesn't own yet
-- (uniformly); rarities with nothing left drop out and the odds of the rest scale up (odds() gives
-- the player's own odds, shown before every purchase — Roblox's paid random items rules).
local IS_ROBLOX = typeof(game) == "Instance"
local Flags: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Assets.Flags)
	else require("../Assets/Flags")
local ShopFlags: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Assets.ShopFlags)
	else require("../Assets/ShopFlags")
local Shop: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Shop)
	else require("./Shop")

local Cosmetics = {}

Cosmetics.RARITIES = {
	{ id = "common", name = "Common", odds = 0.62, color = 0x9AA6B2 },
	{ id = "rare", name = "Rare", odds = 0.25, color = 0x3D8BFF },
	{ id = "epic", name = "Epic", odds = 0.10, color = 0xA35BFF },
	{ id = "legendary", name = "Legendary", odds = 0.03, color = 0xFFB22E },
}

--- (mask rows top to bottom; every row the same width)
Cosmetics.skins = {
	-- Common
	{ id = "stripes", name = "Stripes", rarity = "common", scale = 1, tone = -0.22, mask = { "##.." } },
	{ id = "bands", name = "Bands", rarity = "common", scale = 1, tone = -0.22, mask = { "#", "#", ".", "." } },
	{ id = "checker", name = "Checker", rarity = "common", scale = 1, tone = -0.18, mask = { "#.", ".#" } },
	{
		id = "diagonal",
		name = "Diagonal",
		rarity = "common",
		scale = 1,
		tone = -0.24,
		mask = { "#...", ".#..", "..#.", "...#" },
	},
	{
		id = "dots",
		name = "Dots",
		rarity = "common",
		scale = 1,
		tone = 0.32,
		mask = { "....", ".#..", "....", "...." },
	},
	{
		id = "grid",
		name = "Grid",
		rarity = "common",
		scale = 0,
		tone = -0.26,
		mask = { "####", "#...", "#...", "#..." },
	},
	-- Rare
	{
		id = "bricks",
		name = "Bricks",
		rarity = "rare",
		scale = 0,
		tone = -0.3,
		mask = { "########", "#.......", "#.......", "########", "....#...", "....#..." },
	},
	{
		id = "waves",
		name = "Waves",
		rarity = "rare",
		scale = 1,
		tone = -0.24,
		mask = { "#......#", ".#....#.", "..#..#..", "...##..." },
	},
	{
		id = "diamonds",
		name = "Diamonds",
		rarity = "rare",
		scale = 0,
		tone = -0.26,
		mask = { "...##...", "..#..#..", ".#....#.", "#......#", "#......#", ".#....#.", "..#..#..", "...##..." },
	},
	{
		id = "crosshatch",
		name = "Crosshatch",
		rarity = "rare",
		scale = 0,
		tone = -0.24,
		mask = { "#...#", ".#.#.", "..#..", ".#.#.", "#...#" },
	},
	{
		id = "zigzag",
		name = "Zigzag",
		rarity = "rare",
		scale = 1,
		tone = -0.3,
		mask = { "#...#...", ".#.#.#.#", "..#...#." },
	},
	{
		id = "cobble",
		name = "Cobble",
		rarity = "rare",
		scale = 0,
		tone = -0.24,
		mask = { "..####..", ".#....#.", "#......#", "#......#", "####....", "....#..#", ".....##." },
	},
	-- Epic
	{
		id = "stars",
		name = "Starfield",
		rarity = "epic",
		scale = 0,
		tone = 0.42,
		mask = {
			"..........",
			"...#......",
			"..###.....",
			"...#......",
			"..........",
			".......#..",
			"......###.",
			".......#..",
			"..........",
			"..........",
		},
	},
	{
		id = "camo",
		name = "Camouflage",
		rarity = "epic",
		scale = 1,
		tone = -0.3,
		mask = {
			"..###.......##..",
			".#####.....####.",
			".######...#####.",
			"..####.....###..",
			"...##..........#",
			"#.........###.##",
			"##......######..",
			"###....#######..",
			".##.....#####...",
			"..........##....",
			"....##.........#",
			"...#####......##",
			"..#######....###",
			"...#####......#.",
			"....###.........",
			"................",
		},
	},
	{
		id = "circuit",
		name = "Circuit",
		rarity = "epic",
		scale = 0,
		tone = 0.34,
		mask = {
			"#####...",
			"....#...",
			"....#.##",
			"....###.",
			"##......",
			".#......",
			".####..#",
			"....####",
		},
	},
	{
		id = "hex",
		name = "Hive",
		rarity = "epic",
		scale = 0,
		tone = -0.26,
		mask = {
			".####....",
			"#....#...",
			"#....#...",
			".####....",
			"....#####",
			"...#....#",
			"...#....#",
			"....#####",
		},
	},
	{
		id = "tartan",
		name = "Tartan",
		rarity = "epic",
		scale = 0,
		tone = -0.22,
		mask = {
			"##..#...",
			"##..#...",
			"########",
			"##..#...",
			"########",
			"##..#...",
			"##..#...",
			"##..#...",
		},
	},
	-- Legendary: a fixed accent over any colour
	{
		id = "gilded",
		name = "Gilded",
		rarity = "legendary",
		scale = 0,
		accent = 0xE9B949,
		mask = { "...##...", "..#..#..", ".#....#.", "#......#", "#......#", ".#....#.", "..#..#..", "...##..." },
	},
	{
		id = "frost",
		name = "Frost",
		rarity = "legendary",
		scale = 0,
		accent = 0xF2F8FF,
		mask = {
			"...#....",
			".#.#.#..",
			"..###...",
			"#######.",
			"..###...",
			".#.#.#..",
			"...#....",
			"........",
		},
	},
	{
		id = "obsidian",
		name = "Obsidian",
		rarity = "legendary",
		scale = 0,
		accent = 0x15151C,
		mask = { "#...#", ".#.#.", "..#..", ".#.#.", "#...#" },
	},
	{
		id = "ember",
		name = "Ember",
		rarity = "legendary",
		scale = 1,
		accent = 0xFF6A2B,
		mask = { "#......#", ".#....#.", "..#..#..", "...##..." },
	},
}

--- Skins made for one player (2026-10-18: a custom background for the player @ilyannna, from a clip
--- of a Tie Dye pattern). Never in a crate, never on a
--- bot player, not in the Locker's "N of M": the `owners` (Roblox user ids) own them (Purchases), and it
--- goes on the first time they join with it. Several colours: in `mask`, '.' is the owner's own fill and
--- '1'..'9', 'a'..'z' are colors[1..], drawn at `alpha`.
Cosmetics.exclusive_skins = {
	-- TIE_DYE_BEGIN (tools/assets/tie_dye.py writes this entry)
	{
		id = "tie_dye",
		name = "Tie Dye",
		owners = { 58387889 }, -- ilyannna
		scale = 0,
		alpha = 166,
		colors = { 0xD45881, 0xDA846A, 0xDEB077, 0x7FA88C, 0x6D91D5, 0xA467CF, 0xCFAADA },
		mask = {
			"71122334443333332211665576667776",
			"61122733333333332217655555666666",
			"67122222222233332216655555555556",
			"66172222222227322116555574444755",
			"56112227112222221166555444473445",
			"56711111111222711665555443333334",
			"45671111117271166755554433222233",
			"45566711172211665557444432211723",
			"44556671122211655444444322111123",
			"34455661722216754444433221666123",
			"74455661222216554447332716556123",
			"44455661223325544443322165541233",
			"44555611273344444447321665443334",
			"55556112233344447744321655744444",
			"55661122333334455544321665555755",
			"56611273333334455554322166655555",
			"66112333333344755554332711666555",
			"66123344444444555554433222116666",
			"61223444444455555554433332211666",
			"11233444445556665554444433321177",
			"72733444455666666554444444372111",
			"23337444756611166555444444332222",
			"33374444756711116655555544733223",
			"34444444556111111666755544733333",
			"44444444556111111176666574333337",
			"44444444556611111111176554433337",
			"74444445556611111177116654443333",
			"33334475555562117222211655553223",
			"27333475555432222222211665566122",
			"22233445555432222222711666661112",
			"11223745554433222222116666661111",
			"11127344444733322221166666671111",
		},
	},
	-- TIE_DYE_END
}

--- How an exclusive item shows in the Locker (not a crate rarity: no odds).
Cosmetics.EXCLUSIVE = { id = "exclusive", name = "Exclusive", odds = 0, color = 0xFF6FD8 }

--- Alpha of the secondary tiles (the primary fill is MapSurface.TERRITORY_ALPHA, 150).
Cosmetics.SECONDARY_ALPHA = 190

type Item = { id: string, kind: string, name: string, rarity: string, [string]: any }

local items: { [string]: Item } = {}
local order: { Item } = {}
for _, s in Cosmetics.skins do
	local it: any = table.clone(s)
	it.kind = "skin"
	items[it.id] = it
	table.insert(order, it)
end
for _, f in (Flags.flags or {}) :: { any } do
	local it: any = table.clone(f)
	it.id = "flag_" .. f.code
	it.kind = "flag"
	it.rarity = "common"
	items[it.id] = it
	table.insert(order, it)
end
-- (exclusives resolve by id like any item, but stay out of `order`: the crates, their odds, bot players)
local exclusives: { Item } = {}
local granted: { [number]: { string } } = {}
for _, s in Cosmetics.exclusive_skins do
	local it: any = table.clone(s)
	it.kind = "skin"
	it.rarity = "exclusive"
	it.exclusive = true
	items[it.id] = it
	table.insert(exclusives, it)
	for _, uid in s.owners or {} do
		granted[uid] = granted[uid] or {}
		table.insert(granted[uid], it.id)
	end
end

-- (shop flags resolve by id too, and stay out of `order` like the exclusives)
local shop_items: { Item } = {}
for _, f in Shop.flags() do
	local it: any = {
		id = Shop.item_id(f.key),
		kind = "flag",
		shop = true,
		key = f.key,
		name = f.name,
		rarity = f.rarity,
		theme = f.theme,
		set = f.set,
		image = (ShopFlags.atlases or {})[f.atlas] or "",
		x = f.x,
		y = f.y,
		w = f.w,
		h = f.h,
		big_rect = f.big_rect,
	}
	items[it.id] = it
	table.insert(shop_items, it)
end

function Cosmetics.item(id: any): Item?
	return if type(id) == "string" then items[id] else nil
end

--- Every crate item (skins first, then flags by code). Exclusives are not in it (Cosmetics.exclusives).
function Cosmetics.all(): { Item }
	return order
end

--- The items made for particular players (Cosmetics.exclusive_skins).
function Cosmetics.exclusives(): { Item }
	return exclusives
end

--- The flag shop's flags (Data/Shop), as items.
function Cosmetics.shop_items(): { Item }
	return shop_items
end

--- The exclusive item ids made for Roblox user `user_id` (empty for everyone else).
function Cosmetics.granted(user_id: any): { string }
	return if type(user_id) == "number" then (granted[user_id] or {}) else {}
end

--- May user `user_id` own item `id`? Any crate item; an exclusive only for its owners.
function Cosmetics.may_own(id: any, user_id: any): boolean
	local it = Cosmetics.item(id)
	if it == nil then
		return false
	end
	if not it.exclusive then
		return true
	end
	for _, g in Cosmetics.granted(user_id) do
		if g == id then
			return true
		end
	end
	return false
end

--- How many crate items a set of owned ids holds (the Locker's "N of M"; exclusives and shop flags
--- don't count).
function Cosmetics.crate_owned(owned: { [string]: any }): number
	local n = 0
	for id in owned do
		local it = items[id]
		if it ~= nil and not it.exclusive and not it.shop then
			n += 1
		end
	end
	return n
end

function Cosmetics.rarity(id: string): any
	if id == "exclusive" then
		return Cosmetics.EXCLUSIVE
	end
	for _, r in Cosmetics.RARITIES do
		if r.id == id then
			return r
		end
	end
	return Cosmetics.RARITIES[1]
end

--- The flag atlas image of a flag item (its x, y, w, h: the rect in it).
function Cosmetics.flag_image(it: any): string
	if it and it.shop then
		return it.image or ""
	end
	local a = Flags.atlases or {}
	return if it and it.atlas then (a[it.atlas] or "") else ""
end

--- A flag item at its largest: (image, x, y, w, h). A shop flag has a big sheet (the shop's cards);
--- any other flag is its usual rect.
function Cosmetics.flag_big(it: any): (string, number, number, number, number)
	local r = it and it.big_rect
	local img = if type(r) == "table" then (ShopFlags.big or {})[r[1]] else nil
	if img ~= nil then
		return img, r[2], r[3], r[4], r[5]
	end
	return Cosmetics.flag_image(it), it and it.x or 0, it and it.y or 0, it and it.w or 0, it and it.h or 0
end

--- A player's Roblox head shot: the `face` of a match's cosmetics map is their user id (since
--- 2026-10-04 a little Roblox head picture shows next to each username).
function Cosmetics.face_image(user_id: number): string
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", user_id)
end

--- The player's own odds per rarity: RARITIES' odds over the rarities that still have an item they
--- don't own (owned: set of item ids). { {rarity, odds, left} } in RARITIES order; odds sum to 1 (0 each
--- when everything is owned).
function Cosmetics.odds(owned: { [string]: any }): { { rarity: any, odds: number, left: number } }
	local out = {}
	local total = 0.0
	for _, r in Cosmetics.RARITIES do
		local left = 0
		for _, it in order do
			if it.rarity == r.id and not owned[it.id] then
				left += 1
			end
		end
		table.insert(out, { rarity = r, odds = if left > 0 then r.odds else 0.0, left = left })
		if left > 0 then
			total += r.odds
		end
	end
	for _, e in out do
		e.odds = if total > 0 then e.odds / total else 0.0
	end
	return out
end

--- Roll a crate: an item the player doesn't own (nil when they own everything). r1, r2 in [0, 1).
function Cosmetics.roll(owned: { [string]: any }, r1: number, r2: number): string?
	local odds = Cosmetics.odds(owned)
	local x = r1
	local pick = nil
	for _, e in odds do
		if e.odds > 0 then
			pick = e
			if x < e.odds then
				break
			end
			x -= e.odds
		end
	end
	if pick == nil then
		return nil
	end
	local pool = {}
	for _, it in order do
		if it.rarity == pick.rarity.id and not owned[it.id] then
			table.insert(pool, it.id)
		end
	end
	return pool[math.clamp(math.floor(r2 * #pool) + 1, 1, #pool)]
end

--- The colour number of mask character `ch`: 0 for the owner's own fill ('.' or anything unknown), 1 for
--- '#' (a two-tone skin's secondary), '1'..'9' -> 1..9 and 'a'..'z' -> 10..35 (a skin's `colors`).
local function mask_key(ch: string): number
	if ch == "#" then
		return 1
	end
	local b = string.byte(ch)
	if b >= 49 and b <= 57 then -- '1'..'9'
		return b - 48
	elseif b >= 97 and b <= 122 then -- 'a'..'z'
		return b - 87
	end
	return 0
end

--- A skin's mask as a buffer of w * h bytes for MapSurface: 0 = the owner's fill, 1 = a two-tone skin's
--- secondary, or k = colors[k] of a skin with `colors`.
function Cosmetics.mask(skin: any): (buffer, number, number)
	local rows = skin.mask
	local h = #rows
	local w = 0
	for _, row in rows do
		w = math.max(w, #row)
	end
	local b = buffer.create(w * h)
	for y, row in rows do
		for x = 1, #row do
			buffer.writeu8(b, (y - 1) * w + (x - 1), mask_key(string.sub(row, x, x)))
		end
	end
	return b, w, h
end

--- colors[k] of a skin with several colours as (r, g, b) floats (nil past its list, or a two-tone skin).
function Cosmetics.color(skin: any, k: number): (number?, number?, number?)
	local list = skin.colors
	local c = if type(list) == "table" then list[k] else nil
	if type(c) ~= "number" then
		return nil, nil, nil
	end
	return ((c // 65536) % 256) / 255, ((c // 256) % 256) / 255, (c % 256) / 255
end

--- The alpha (0..255) a skin's own colours are drawn at.
function Cosmetics.skin_alpha(skin: any): number
	return if type(skin.alpha) == "number" then skin.alpha else Cosmetics.SECONDARY_ALPHA
end

--- The secondary colour (r, g, b floats) of `skin` over a territory of colour (r, g, b).
function Cosmetics.secondary(skin: any, r: number, g: number, b: number): (number, number, number)
	local a = skin.accent
	if type(a) == "number" then
		return ((a // 65536) % 256) / 255, ((a // 256) % 256) / 255, (a % 256) / 255
	end
	local t = tonumber(skin.tone) or -0.2
	if t >= 0 then
		return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
	end
	return r * (1 + t), g * (1 + t), b * (1 + t)
end

return Cosmetics
