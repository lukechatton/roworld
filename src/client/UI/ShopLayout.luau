--!strict
-- The flag shop's layout (UI/FlagShop), apart so tests can run it without Roblox: the order of a
-- section's cards and where each goes, with a section's Legendary on a FEATURED card 2 x 2 cells big
-- (2026-10-24).
local IS_ROBLOX = typeof(game) == "Instance"
local Shop: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Shop)
	else (require :: any)("../../shared/Data/Shop")

local ShopLayout = {}

--- Where the cards go in a grid `cols` wide: with `hero`, the first is the FEATURED card on the
--- top-left 2 x 2 cells and the other `n` - 1 fill the cells around it row by row. { {col, row} } (0-based,
--- the hero's first), and the rows used.
function ShopLayout.place(n: number, hero: boolean, cols: number): ({ { number } }, number)
	cols = math.max(2, cols)
	local taken: { [number]: boolean } = {}
	local cells = {}
	local rows = 0
	local start = 1
	if hero and n > 0 then
		table.insert(cells, { 0, 0 })
		for _, c in { 0, 1, cols, cols + 1 } do
			taken[c] = true
		end
		rows = 2
		start = 2
	end
	local k = 0
	for _ = start, n do
		while taken[k] do
			k += 1
		end
		taken[k] = true
		table.insert(cells, { k % cols, k // cols })
		rows = math.max(rows, k // cols + 1)
		k += 1
	end
	return cells, rows
end

--- The keys rarest first (the priciest as the shop's eye-catchers), and whether the first is a Legendary
--- that gets the FEATURED card.
function ShopLayout.order(keys: { string }): ({ string }, boolean)
	local list = table.clone(keys)
	local rank = { legendary = 1, epic = 2, rare = 3 }
	table.sort(list, function(a, b)
		local fa, fb = Shop.flag(a), Shop.flag(b)
		local ra, rb = rank[fa and fa.rarity or ""] or 9, rank[fb and fb.rarity or ""] or 9
		if ra ~= rb then
			return ra < rb
		end
		return (fa and fa.name or a) < (fb and fb.name or b)
	end)
	local top = Shop.flag(list[1])
	return list, #list > 1 and top ~= nil and top.rarity == "legendary"
end

return ShopLayout
