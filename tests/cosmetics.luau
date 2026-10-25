--!nocheck
-- Cosmetics (Data/Cosmetics): the catalog, the player's odds, crate rolls (never a duplicate, rarity
-- shares follow the published odds), and a territory skin in MapSurface.tile_pixel.
require("./prelude")
local Cosmetics = require("../src/shared/Data/Cosmetics")
local Flags = require("../src/shared/Assets/Flags")
local MapSurface = require("../src/client/Map/MapSurface")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- catalog
local ids, skins, flags = {}, 0, 0
local dup = false
local rare_ok = true
for _, it in Cosmetics.all() do
	if ids[it.id] then
		dup = true
	end
	ids[it.id] = true
	if it.kind == "skin" then
		skins += 1
		local w = #it.mask[1]
		for _, row in it.mask do
			if #row ~= w or string.find(row, "[^#.]") then
				print("  bad mask row in " .. it.id .. ": " .. row)
				rare_ok = false
			end
		end
		if it.tone == nil and it.accent == nil then
			rare_ok = false
		end
	else
		flags += 1
		if not (it.w > 0 and it.h > 0 and Cosmetics.flag_image(it) ~= nil) then
			rare_ok = false
		end
	end
	local known = false
	for _, r in Cosmetics.RARITIES do
		known = known or r.id == it.rarity
	end
	rare_ok = rare_ok and known
end
expect(not dup, "item ids are unique")
expect(rare_ok, "masks rectangular, every skin coloured, every flag has an image rect, rarities known")
expect(skins >= 20 and flags == #Flags.flags and flags > 250, string.format("%d skins, %d flags", skins, flags))
expect(Cosmetics.item("flag_ne") == nil, "no Niger flag")
local sum = 0
for _, r in Cosmetics.RARITIES do
	sum += r.odds
end
expect(math.abs(sum - 1) < 1e-9, "published odds sum to 100%")

-- the player's odds: rarities with nothing left drop out
local owned = {}
for _, it in Cosmetics.all() do
	if it.rarity == "legendary" then
		owned[it.id] = true
	end
end
local o = Cosmetics.odds(owned)
local total = 0
for _, e in o do
	total += e.odds
	if e.rarity.id == "legendary" then
		expect(e.odds == 0 and e.left == 0, "every legendary owned: 0% legendary")
	end
end
expect(math.abs(total - 1) < 1e-9, "the rest scale up to 100% (" .. total .. ")")

-- rolls: never a duplicate until everything is owned; shares follow the odds
math.randomseed(5)
local mine = {}
local n_items = #Cosmetics.all()
local first_dupe = false
for k = 1, n_items do
	local id = Cosmetics.roll(mine, math.random(), math.random())
	if id == nil or mine[id] then
		first_dupe = true
		break
	end
	mine[id] = true
end
expect(not first_dupe, n_items .. " crates: " .. n_items .. " different items")
expect(Cosmetics.roll(mine, 0.5, 0.5) == nil, "everything owned: nothing to roll")
local counts = {}
local N = 40000
for _ = 1, N do
	local id = Cosmetics.roll({}, math.random(), math.random())
	local r = Cosmetics.item(id).rarity
	counts[r] = (counts[r] or 0) + 1
end
local close = true
for _, r in Cosmetics.RARITIES do
	local share = (counts[r.id] or 0) / N
	if math.abs(share - r.odds) > 0.01 then
		close = false
	end
	print(string.format("       %-9s %.1f%% (published %.0f%%)", r.name, share * 100, r.odds * 100))
end
expect(close, "rolled rarity shares match the published odds (±1%)")

-- MapSurface: a skinned owner's tiles alternate primary / secondary as its mask says
do
	local W, H = 8, 4
	local own = buffer.create(W * H * 4)
	for i = 0, W * H - 1 do
		buffer.writei32(own, i * 4, 3)
	end
	local surf = setmetatable({
		W = W,
		N = W * H,
		_own = own,
		_flags = buffer.create(W * H),
		defended = buffer.create(W * H),
		pal_fill = buffer.create(64 * 4),
		pal_fill_hi = buffer.create(64 * 4),
		hover = 0,
		_skins = {},
		_state = { cosmetics = { [3] = { skin = "stripes" } }, are_allies = function()
			return false
		end },
	}, MapSurface)
	buffer.writeu32(surf.pal_fill, 3 * 4, 0x96112233)
	surf:_load_skins(nil)
	local sk = surf._skins[3]
	sk.fill2 = 0xBE445566
	-- interior row 1 (row 0 and the edges are border tiles): stripes "##.." at scale 1 = tiles 0-3 on, 4-7 off
	local got = {}
	for x = 1, 6 do
		table.insert(got, if surf:tile_pixel(1 * W + x) == sk.fill2 then "#" else ".")
	end
	expect(table.concat(got) == "###...", "stripes at scale 1 on row 1, x 1..6: " .. table.concat(got))
	surf._state.cosmetics[3] = nil
	surf:_load_skins({ 3 })
	expect(surf._skins[3] == nil and surf:tile_pixel(W + 1) == 0x96112233, "unequipped: the plain fill")
end

-- Exclusive skins (Cosmetics.exclusive_skins; 2026-10-18, Tie Dye for ilyannna): their owners only,
-- never in a crate, several colours
do
	local ILYANNNA = 58387889
	local td = Cosmetics.item("tie_dye")
	expect(td ~= nil and td.kind == "skin" and td.exclusive == true and td.rarity == "exclusive", "tie_dye resolves")
	local in_all = false
	for _, it in Cosmetics.all() do
		in_all = in_all or it.exclusive == true or it.id == "tie_dye"
	end
	expect(not in_all, "no exclusive in the crate catalog (Cosmetics.all)")
	expect(Cosmetics.rarity("exclusive").name == "Exclusive", "the Exclusive label")
	local g = Cosmetics.granted(ILYANNNA)
	expect(#g == 1 and g[1] == "tie_dye", "ilyannna's user id is granted tie_dye")
	expect(#Cosmetics.granted(1) == 0 and #Cosmetics.granted(nil) == 0, "nobody else is granted anything")
	expect(Cosmetics.may_own("tie_dye", ILYANNNA) and not Cosmetics.may_own("tie_dye", 1), "may_own: its owner only")
	expect(Cosmetics.may_own("stripes", 1) and Cosmetics.may_own("stripes", nil), "may_own: crate items for anyone")
	expect(not Cosmetics.may_own("nope", ILYANNNA), "may_own: unknown ids for nobody")
	expect(Cosmetics.crate_owned({ tie_dye = true, stripes = true }) == 1, "crate_owned leaves exclusives out")
	-- a player owning every crate item still has nothing to roll (the exclusive is not in crates)
	local all = {}
	for _, it in Cosmetics.all() do
		all[it.id] = true
	end
	expect(Cosmetics.roll(all, 0.5, 0.5) == nil, "everything in crates owned: no roll, though tie_dye is not")
	local exids = {}
	for _, it in Cosmetics.all() do
		exids[it.id] = true
	end
	local ok = true
	for _, it in Cosmetics.exclusives() do
		if exids[it.id] then
			ok = false
		end
		exids[it.id] = true
		local mask, w, h = Cosmetics.mask(it)
		for _, row in it.mask do
			ok = ok and #row == w
		end
		for i = 0, w * h - 1 do
			local k = buffer.readu8(mask, i)
			ok = ok and (k == 0 or (k <= #it.colors and Cosmetics.color(it, k) ~= nil))
		end
		for _, c in it.colors do
			ok = ok and type(c) == "number" and c >= 0 and c <= 0xFFFFFF
		end
		local a = Cosmetics.skin_alpha(it)
		ok = ok and a > 0 and a <= 255 and w >= 1 and h >= 1 and w <= 64 and h <= 64
	end
	expect(ok, "exclusive masks rectangular, every key has a colour, ids unique across the catalog")

	-- MapSurface: each tile takes its mask key's colour; '.' keeps the owner's fill
	local W, H = 10, 6
	local own = buffer.create(W * H * 4)
	for i = 0, W * H - 1 do
		buffer.writei32(own, i * 4, 3)
	end
	local surf = setmetatable({
		W = W,
		N = W * H,
		_own = own,
		_flags = buffer.create(W * H),
		defended = buffer.create(W * H),
		pal_fill = buffer.create(64 * 4),
		pal_fill_hi = buffer.create(64 * 4),
		hover = 0,
		_skins = {},
		_state = { cosmetics = { [3] = { skin = "tie_dye" } }, are_allies = function()
			return false
		end },
	}, MapSurface)
	buffer.writeu32(surf.pal_fill, 3 * 4, 0x96112233)
	surf:_load_skins(nil)
	local sk = surf._skins[3]
	expect(sk ~= nil and sk.fills ~= nil, "tie_dye loads with a colour list")
	for k = 1, #td.colors do
		sk.fills[k] = 0xC8000000 + k
	end
	local mask, mw, mh = Cosmetics.mask(td)
	local match = true
	for y = 1, H - 2 do
		for x = 1, W - 2 do
			local k = buffer.readu8(mask, (bit32.rshift(y, td.scale) % mh) * mw + bit32.rshift(x, td.scale) % mw)
			local want = if k == 0 then 0x96112233 else 0xC8000000 + k
			match = match and surf:tile_pixel(y * W + x) == want
		end
	end
	expect(match, "tie_dye interior tiles: colors[mask key], the owner's fill for '.'")
end

if fails > 0 then
	error(fails .. " failures")
end
print("cosmetics: all passed")
